// Benchmark driver: sends each scenario's symptom-mode prompt to an already-running llama-server, grades the
// response with grade.mjs, and prints one JSON line per scenario to stdout (setup.sh's --benchmark mode
// reformats each line into its own [ ok ]/[warn]/[fail] display). This file is the only place prompt
// construction and HTTP-calling logic lives -- setup.sh stays free of both, matching how it already reuses
// this same grade.mjs module rather than duplicating scoring logic.
//
// Requires an already-running, already-validated server (setup.sh checks that before invoking this) -- this
// driver never boots one itself, same division of responsibility as --doctor.
//
// Usage: node bench.mjs <scenario-id|all> --port <port> [--max-tokens N]
import { readFileSync, readdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { grade } from "./grade.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCEN_DIR = path.join(HERE, "scenarios");
const ORACLE_DIR = path.join(HERE, "oracle");

function parseArgs(argv) {
  const args = { target: "all", port: 8114, maxTokens: 3072, timeoutMs: 300_000 };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--port") args.port = Number(argv[++i]);
    else if (a === "--max-tokens") args.maxTokens = Number(argv[++i]);
    else if (a === "--timeout-ms") args.timeoutMs = Number(argv[++i]);
    else rest.push(a);
  }
  if (rest[0]) args.target = rest[0];
  return args;
}

function loadScenarios(target) {
  const available = readdirSync(SCEN_DIR).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5)).sort();
  const ids = target === "all" ? available : [target];
  return ids.map((id) => {
    if (!available.includes(id)) {
      console.error(`unknown scenario "${id}" -- available: ${available.join(", ")}, or "all"`);
      process.exit(64);
    }
    return JSON.parse(readFileSync(path.join(SCEN_DIR, `${id}.json`), "utf8"));
  });
}

// Verbatim port of multifile_eval.py's build_prompt symptom branch -- the `=== path === ``` body``` ` framing
// is not a style choice, it is what grade.mjs's splitFiles() actually parses, and the two were designed
// together against real captured model output in the research repo this was ported from.
function buildSymptomPrompt(scenario) {
  const blocks = Object.entries(scenario.files)
    .map(([p, c]) => `=== ${p} ===\n\`\`\`\n${c}\`\`\``)
    .join("\n\n");
  return (
    `You are fixing bugs in a ${scenario.stack} app.\n\n` +
    `Bug reports from users:\n${scenario.report}\n\n` +
    `Here are the relevant files:\n\n${blocks}\n\n` +
    `Fix ALL the bugs. Output the complete corrected content of only the files you change, each as:\n\n` +
    `=== <path> ===\n\`\`\`\n<full corrected file>\n\`\`\`\n\nNo explanation.`
  );
}

async function complete(prompt, { port, maxTokens, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        messages: [{ role: "user", content: prompt }],
        max_tokens: maxTokens,
        temperature: 0,
      }),
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`http ${res.status}`);
    const body = await res.json();
    const content = body?.choices?.[0]?.message?.content ?? "";
    const reasoning = body?.choices?.[0]?.message?.reasoning_content ?? "";
    return { content, reasoning };
  } finally {
    clearTimeout(timer);
  }
}

async function runScenario(scenario, opts) {
  const t0 = Date.now();
  if (scenario.valid_modes && !scenario.valid_modes.includes("symptom")) {
    return { scenario: scenario.id, verdict: "skip", detail: "symptom mode not valid for this scenario" };
  }
  const prompt = buildSymptomPrompt(scenario);
  let content, reasoning;
  try {
    ({ content, reasoning } = await complete(prompt, opts));
  } catch (e) {
    const wall_s = (Date.now() - t0) / 1000;
    const timedOut = e.name === "AbortError";
    return { scenario: scenario.id, verdict: timedOut ? "timeout" : "error", detail: e.message, wall_s };
  }
  const wall_s = (Date.now() - t0) / 1000;
  if (!content && reasoning) {
    return { scenario: scenario.id, verdict: "empty-reasoning", detail: "reasoning channel non-empty, content empty", wall_s };
  }
  if (!content) {
    return { scenario: scenario.id, verdict: "error", detail: "empty response", wall_s };
  }

  const scratchDir = mkdtempSync(path.join(tmpdir(), "gemma4-kit-bench-"));
  try {
    const bugs = grade(scenario, content, ORACLE_DIR, scratchDir);
    const pass = bugs.filter((b) => b.pass).length;
    return { scenario: scenario.id, verdict: "ok", pass, total: bugs.length, wall_s, bugs };
  } catch (e) {
    // grade() itself threw (not an oracle failure -- those come back as pass:false). Most likely a Node too
    // old for --experimental-strip-types, or a missing oracle tree. Reported per scenario, never re-thrown,
    // so one broken scenario can't abort the rest of the batch.
    return { scenario: scenario.id, verdict: "error", detail: `grading failed: ${e.message}`, wall_s };
  } finally {
    rmSync(scratchDir, { recursive: true, force: true });
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const scenarios = loadScenarios(opts.target);
  for (const scenario of scenarios) {
    let result;
    try {
      result = await runScenario(scenario, opts);
    } catch (e) {
      result = { scenario: scenario.id, verdict: "error", detail: e.message };
    }
    console.log(JSON.stringify(result));
  }
}

main();
