/**
 * Gemma-4 tool-call grammar recovery for `pi`.
 *
 * llama.cpp's Gemma-4 chat format (COMMON_CHAT_FORMAT_PEG_GEMMA4, common/chat.cpp) encodes tool calls with
 * native special tokens rather than JSON: a well-formed call looks like
 *   <|tool_call>call:toolName{key:<|"|>value<|"|>,otherKey:123}<tool_call|>
 * (string values are wrapped in `<|"|>...<|"|>` instead of `"`, dict keys are bare text up to `:`). This is a
 * fragile, actively-churning parser path in llama.cpp (see ggml-org/llama.cpp #22786, #21375, #21316): a
 * decoding hiccup anywhere in that token sequence produces a leaked, unparseable fragment instead of a real
 * tool call -- observed directly on this kit (EXP-077): a lone `<tool_call|>` closing token with no opener,
 * no name, no arguments, surfacing inside the `thinking`/reasoning_content channel, with `stopReason: "stop"`
 * and zero tool results. Silent, no error, no edit.
 *
 * This extension does two things, mirroring the architecture of the (excellent, but Gemma-4-agnostic)
 * pi-tool-repair package -- https://github.com/monotykamary/pi-tool-repair -- which already covers this exact
 * problem for DeepSeek/Qwen/Kimi/Mistral/Llama/GLM/Granite/MiniMax/OLMo but has no Gemma-4 grammar entry:
 *
 *   1. Recovery: if a COMPLETE `<|tool_call>call:name{...}<tool_call|>` span is found leaked in a `text` or
 *      `thinking` content part, parse the gemma4-dict body into real JSON arguments and replace the leaked
 *      text with a proper `toolCall` content block -- pi then executes it normally.
 *   2. Retry: if the tokens are present but INCOMPLETE (no full span to recover -- exactly the observed
 *      failure) and the turn ended with `stopReason: "stop"` and zero tool results, inject one corrective
 *      follow-up turn asking the model to reissue the call. Capped at 2 consecutive corrections so a model
 *      that's genuinely stuck (not just malformed) doesn't loop forever; the counter resets on any turn that
 *      makes real progress (a tool call executes, or the model produces real assistant text).
 *
 * Install: `pi install ./gemma4-tool-recovery.ts` (or add to `~/.pi/agent/settings.json`'s `extensions` array).
 * Scoped to models whose id/name matches /gemma.?4/i by default -- see GEMMA4_MODEL_PATTERN below.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const GEMMA4_MODEL_PATTERN = /gemma.?4|gemma4/i;
const MAX_CONSECUTIVE_RETRIES = 2;

const TOOL_CALL_OPEN = "<|tool_call>call:";
const TOOL_CALL_CLOSE = "<tool_call|>";
const LEAK_MARKERS = ["<|tool_call>", "<tool_call|>", "<|channel>", "<channel|>"];

interface RecoveredCall {
  name: string;
  arguments: Record<string, unknown>;
}

interface ContentPart {
  type: string;
  text?: string;
  thinking?: string;
  [key: string]: unknown;
}

interface AssistantMessage {
  role: string;
  content: ContentPart[];
  stopReason?: string;
  [key: string]: unknown;
}

function getPartText(part: ContentPart): string | undefined {
  if (part.type === "text" && typeof part.text === "string") return part.text;
  if (part.type === "thinking" && typeof part.thinking === "string") return part.thinking;
  return undefined;
}

function setPartText(part: ContentPart, text: string): ContentPart {
  if (part.type === "text") return { ...part, text };
  if (part.type === "thinking") return { ...part, thinking: text };
  return part;
}

// Parses a gemma4-dict body (already stripped of the outer `{` `}`) into a plain object.
// Grammar (common/chat.cpp): keys are bare text up to `:`; string values are `<|"|>...<|"|>`-wrapped;
// numbers/bools/null are plain JSON tokens; nested `{...}`/`[...]` recurse.
function parseGemma4Value(text: string, pos: number): { value: unknown; next: number } | undefined {
  while (pos < text.length && /\s/.test(text[pos])) pos++;
  if (text.startsWith('<|"|>', pos)) {
    const end = text.indexOf('<|"|>', pos + 5);
    if (end === -1) return undefined;
    return { value: text.slice(pos + 5, end), next: end + 5 };
  }
  if (text[pos] === "{") {
    const obj: Record<string, unknown> = {};
    let p = pos + 1;
    while (p < text.length) {
      while (p < text.length && /\s/.test(text[p])) p++;
      if (text[p] === "}") return { value: obj, next: p + 1 };
      const keyEnd = text.indexOf(":", p);
      if (keyEnd === -1) return undefined;
      const key = text.slice(p, keyEnd).trim();
      const parsed = parseGemma4Value(text, keyEnd + 1);
      if (!parsed) return undefined;
      obj[key] = parsed.value;
      p = parsed.next;
      while (p < text.length && /\s/.test(text[p])) p++;
      if (text[p] === ",") p++;
      else if (text[p] === "}") return { value: obj, next: p + 1 };
      else return undefined;
    }
    return undefined;
  }
  if (text[pos] === "[") {
    const arr: unknown[] = [];
    let p = pos + 1;
    while (p < text.length) {
      while (p < text.length && /\s/.test(text[p])) p++;
      if (text[p] === "]") return { value: arr, next: p + 1 };
      const parsed = parseGemma4Value(text, p);
      if (!parsed) return undefined;
      arr.push(parsed.value);
      p = parsed.next;
      while (p < text.length && /\s/.test(text[p])) p++;
      if (text[p] === ",") p++;
      else if (text[p] === "]") return { value: arr, next: p + 1 };
      else return undefined;
    }
    return undefined;
  }
  // number / bool / null -- read up to the next structural char
  const rest = text.slice(pos).match(/^(true|false|null|-?\d+(?:\.\d+)?)/);
  if (rest) return { value: JSON.parse(rest[1]), next: pos + rest[1].length };
  return undefined;
}

function findCompleteCalls(text: string): { calls: RecoveredCall[]; strippedRanges: Array<[number, number]> } {
  const calls: RecoveredCall[] = [];
  const strippedRanges: Array<[number, number]> = [];
  let searchFrom = 0;
  while (true) {
    const openIdx = text.indexOf(TOOL_CALL_OPEN, searchFrom);
    if (openIdx === -1) break;
    const nameStart = openIdx + TOOL_CALL_OPEN.length;
    const braceIdx = text.indexOf("{", nameStart);
    const closeIdx = text.indexOf(TOOL_CALL_CLOSE, nameStart);
    if (braceIdx === -1 || closeIdx === -1 || braceIdx > closeIdx) {
      searchFrom = openIdx + TOOL_CALL_OPEN.length;
      continue;
    }
    const name = text.slice(nameStart, braceIdx).trim();
    if (!/^[A-Za-z_]\w*$/.test(name)) {
      searchFrom = openIdx + TOOL_CALL_OPEN.length;
      continue;
    }
    const parsed = parseGemma4Value(text, braceIdx);
    if (parsed && parsed.value && typeof parsed.value === "object" && parsed.next <= closeIdx + TOOL_CALL_CLOSE.length) {
      calls.push({ name, arguments: parsed.value as Record<string, unknown> });
      strippedRanges.push([openIdx, closeIdx + TOOL_CALL_CLOSE.length]);
      searchFrom = closeIdx + TOOL_CALL_CLOSE.length;
    } else {
      searchFrom = openIdx + TOOL_CALL_OPEN.length;
    }
  }
  return { calls, strippedRanges };
}

function stripRanges(text: string, ranges: Array<[number, number]>): string {
  const sorted = [...ranges].sort((a, b) => a[0] - b[0]);
  let out = "";
  let cursor = 0;
  for (const [start, end] of sorted) {
    out += text.slice(cursor, start);
    cursor = Math.max(cursor, end);
  }
  out += text.slice(cursor);
  return out.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}

function hasDanglingGemma4Tokens(text: string): boolean {
  return LEAK_MARKERS.some((marker) => text.includes(marker));
}

function isGemma4Model(ctx: { model?: unknown }): boolean {
  try {
    const model = ctx.model as { id?: string; name?: string } | undefined;
    const id = [model?.id, model?.name].filter(Boolean).join(" ");
    return GEMMA4_MODEL_PATTERN.test(id);
  } catch {
    return false;
  }
}

export default function (pi: ExtensionAPI) {
  let consecutiveRetries = 0;
  let pendingMalformedRetry = false;

  pi.on("message_end", (event, ctx) => {
    if (event.message.role !== "assistant") return;
    if (!isGemma4Model(ctx)) return;

    const message = event.message as unknown as AssistantMessage;
    if (!Array.isArray(message.content)) return;

    let changed = false;
    let recoveredAny = false;
    let sawDangling = false;
    const nextContent: ContentPart[] = [];

    for (const part of message.content) {
      const text = getPartText(part);
      if (text === undefined) {
        nextContent.push(part);
        continue;
      }
      const { calls, strippedRanges } = findCompleteCalls(text);
      if (calls.length > 0) {
        changed = true;
        recoveredAny = true;
        nextContent.push(setPartText(part, stripRanges(text, strippedRanges)));
        let idx = 0;
        for (const call of calls) {
          nextContent.push({
            type: "toolCall",
            id: `gemma4_recovery_${Date.now().toString(36)}_${idx++}`,
            name: call.name,
            arguments: call.arguments,
          } as ContentPart);
        }
      } else {
        if (hasDanglingGemma4Tokens(text)) sawDangling = true;
        nextContent.push(part);
      }
    }

    // Only flag "malformed, needs retry" when nothing was recovered, dangling tokens were seen, and the
    // turn otherwise looks like a silent no-op (no real tool call anywhere, stopReason "stop").
    const hasAnyToolCall = message.content.some((p) => p.type === "toolCall") || recoveredAny;
    pendingMalformedRetry = sawDangling && !hasAnyToolCall && message.stopReason === "stop";

    if (!changed) return;

    const nextMessage: AssistantMessage = { ...message, content: nextContent };
    if (recoveredAny) nextMessage.stopReason = "toolUse";
    return { message: nextMessage };
  });

  pi.on("turn_end", async (event, ctx) => {
    if (!isGemma4Model(ctx)) return;

    const madeRealProgress = (event.toolResults?.length ?? 0) > 0;
    if (madeRealProgress) {
      consecutiveRetries = 0;
      pendingMalformedRetry = false;
      return;
    }

    if (!pendingMalformedRetry) {
      consecutiveRetries = 0;
      return;
    }

    pendingMalformedRetry = false;
    if (consecutiveRetries >= MAX_CONSECUTIVE_RETRIES) {
      consecutiveRetries = 0;
      return;
    }
    consecutiveRetries++;

    if (ctx.isIdle()) {
      pi.sendUserMessage(
        "Your last response ended without a valid tool call (it looked like an incomplete or malformed " +
          "tool-call attempt). Please reissue that tool call, formatted correctly, or explain what you were " +
          "trying to do instead.",
      );
    }
  });
}
