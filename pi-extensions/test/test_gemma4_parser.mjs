const TOOL_CALL_OPEN = "<|tool_call>call:";
const TOOL_CALL_CLOSE = "<tool_call|>";

function parseGemma4Value(text, pos) {
  while (pos < text.length && /\s/.test(text[pos])) pos++;
  if (text.startsWith('<|"|>', pos)) {
    const end = text.indexOf('<|"|>', pos + 5);
    if (end === -1) return undefined;
    return { value: text.slice(pos + 5, end), next: end + 5 };
  }
  if (text[pos] === "{") {
    const obj = {};
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
    const arr = [];
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
  const rest = text.slice(pos).match(/^(true|false|null|-?\d+(?:\.\d+)?)/);
  if (rest) return { value: JSON.parse(rest[1]), next: pos + rest[1].length };
  return undefined;
}

function findCompleteCalls(text) {
  const calls = [];
  const strippedRanges = [];
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
      calls.push({ name, arguments: parsed.value });
      strippedRanges.push([openIdx, closeIdx + TOOL_CALL_CLOSE.length]);
      searchFrom = closeIdx + TOOL_CALL_CLOSE.length;
    } else {
      searchFrom = openIdx + TOOL_CALL_OPEN.length;
    }
  }
  return { calls, strippedRanges };
}

// --- Tests ---
function assertEqual(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    console.error(`FAIL ${label}: expected ${e}, got ${a}`);
    process.exitCode = 1;
  } else {
    console.log(`ok   ${label}`);
  }
}

// 1. Simple complete call, one string arg
{
  const text = 'blah <|tool_call>call:read{path:<|"|>src/isWithinInterval/index.ts<|"|>}<tool_call|> trailing';
  const { calls } = findCompleteCalls(text);
  assertEqual(calls, [{ name: "read", arguments: { path: "src/isWithinInterval/index.ts" } }], "simple string arg");
}

// 2. Multiple args, mixed types
{
  const text = '<|tool_call>call:edit{path:<|"|>a.ts<|"|>,oldText:<|"|>foo<|"|>,newText:<|"|>bar<|"|>,limit:5}<tool_call|>';
  const { calls } = findCompleteCalls(text);
  assertEqual(
    calls,
    [{ name: "edit", arguments: { path: "a.ts", oldText: "foo", newText: "bar", limit: 5 } }],
    "multiple mixed args",
  );
}

// 3. Nested object arg
{
  const text = '<|tool_call>call:write{path:<|"|>x<|"|>,meta:{lines:3,ok:true}}<tool_call|>';
  const { calls } = findCompleteCalls(text);
  assertEqual(
    calls,
    [{ name: "write", arguments: { path: "x", meta: { lines: 3, ok: true } } }],
    "nested object arg",
  );
}

// 4. THE ACTUAL OBSERVED FAILURE: dangling close token only, no opener/name/args -- must NOT recover
{
  const text = "<tool_call|>";
  const { calls } = findCompleteCalls(text);
  assertEqual(calls, [], "dangling close-only token recovers nothing (correct -- must trigger retry, not fake recovery)");
}

// 5. Opener with no closer (truncated stream) -- must not recover
{
  const text = '<|tool_call>call:read{path:<|"|>src/foo.ts';
  const { calls } = findCompleteCalls(text);
  assertEqual(calls, [], "truncated opener with no closer recovers nothing");
}

// 6. Text with no tokens at all
{
  const text = "I found the bug in the sort() call.";
  const { calls } = findCompleteCalls(text);
  assertEqual(calls, [], "plain text, no leak, no false positive");
}

console.log(process.exitCode ? "\nSOME TESTS FAILED" : "\nALL TESTS PASSED");
