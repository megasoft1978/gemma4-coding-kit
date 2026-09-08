// Node port of llm-memory-wall-research's scripts/grade_lib.py, so this kit can grade its own benchmark suite
// with zero dependencies beyond the Node that `pi` already requires -- no Python, no separate install.
//
// Faithfulness note: every one of the 173 regex patterns across all 7 scenarios was checked to compile as a
// JS RegExp before this port was written (`new RegExp(p)` on each, zero failures) -- Python's `re` and JS's
// RegExp differ in a few corners (named groups, some lookbehind edge cases), and this suite happens to avoid
// all of them, so a straight regex-semantics port is safe here. If a future scenario adds a pattern that
// doesn't compile in JS, that will surface immediately as a thrown SyntaxError, not a silent wrong grade.
//
// Two grading paths, matching the original:
//   1. Pattern rules (`all`/`any`/`forbid`, or legacy single `pass`) scoped to a named file or file list.
//   2. Executable-oracle bugs (`"oracle": true`) -- graded by actually running the code, see runOracle().

import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";

// Python's original used `\Z` (absolute end-of-string) for the "unterminated fence" fallback. JS has no
// direct equivalent under the `m` flag -- a bare `$` there matches at the end of EVERY line, not just the
// true end of input, which made the lazy body capture stop after just the first line (confirmed by testing:
// it silently truncated every multi-line file to one line). `(?![\s\S])` is the correct "true end of input"
// assertion: a negative lookahead for "any character at all", which only succeeds when there is none left.
const FENCE_RE = /^\s*```[a-zA-Z0-9_+-]*\s*\n(?<body>[\s\S]*?)(?:^\s*```\s*$|(?![\s\S]))/m;

// A relative import specifier with no recognised extension, e.g. `from "./channels/email"` -- normal for
// bundler-style TypeScript, but Node's native ESM loader needs an explicit extension. Applied only at
// grading/oracle-run time, never to what the model is shown.
const BARE_RELATIVE_IMPORT = /(from\s+|import\s*\(\s*)(['"])(\.\.?\/[^'"]+?)(?<!\.ts)(?<!\.tsx)(?<!\.js)(?<!\.mjs)(?<!\.json)\2/g;

export function fixTsImports(source) {
  return source.replace(BARE_RELATIVE_IMPORT, (_m, kw, q, spec) => `${kw}${q}${spec}.ts${q}`);
}

/** Split harness output into {path: body}. Later emissions of a path win (a follow-up turn supersedes). */
export function splitFiles(out) {
  const files = {};
  const headerRe = /^\s*={2,}\s*([^=\n]+?)\s*={2,}\s*$/gm;
  const marks = [...out.matchAll(headerRe)];
  for (let i = 0; i < marks.length; i++) {
    const m = marks[i];
    const end = i + 1 < marks.length ? marks[i + 1].index : out.length;
    const chunk = out.slice(m.index + m[0].length, end);
    const fence = chunk.match(FENCE_RE);
    const body = fence ? fence.groups.body : chunk;
    let p = m[1].trim().replace(/^`+|`+$/g, "").replace(/^\.?\//, "");
    if (p) files[p] = (files[p] || "") + "\n" + body;
  }
  return files;
}

/** Remove // and /* *\/ comments (and JSX {/* *\/} via the same block-comment path), keeping string literals
 * intact -- comments are not code and must never satisfy a rule. */
export function stripComments(code) {
  const out = [];
  let i = 0;
  const n = code.length;
  while (i < n) {
    const c = code[i];
    if (c === '"' || c === "'" || c === "`") {
      const quote = c;
      out.push(c);
      i++;
      while (i < n) {
        if (code[i] === "\\") { out.push(code.slice(i, i + 2)); i += 2; continue; }
        out.push(code[i]);
        if (code[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }
    if (code.startsWith("//", i)) {
      const j = code.indexOf("\n", i);
      i = j === -1 ? n : j;
      continue;
    }
    if (code.startsWith("/*", i)) {
      const j = code.indexOf("*/", i + 2);
      i = j === -1 ? n : j + 2;
      out.push(" ");
      continue;
    }
    out.push(c);
    i++;
  }
  return out.join("");
}

export function norm(text) {
  return text.replace(/\s+/g, " ");
}

/** Text a rule is evaluated against: the named file(s) when `want` is given, else the whole output. */
function scopeText(out, files, want) {
  let body;
  if (want == null) {
    body = out;
  } else {
    const wants = Array.isArray(want) ? want : [want];
    body = Object.entries(files)
      .filter(([k]) => wants.some((w) => k.includes(w)))
      .map(([, v]) => v)
      .join("\n");
  }
  return norm(stripComments(body));
}

// All 173 patterns in this suite were authored for Python's `re`, then checked to compile as a JS RegExp --
// but "compiles" isn't "means the same thing". `\A` (Python's absolute start-of-string anchor) is not a
// recognised JS escape, and outside Unicode mode JS silently treats an unrecognised letter escape as that
// literal character instead of raising an error -- so `/\A/` in JS matches a literal "A", not "start of
// string". Confirmed directly: `/\A/.test("xAy")` is true, `/\A/.test("yx")` is false. This is exactly the
// kind of thing that only shows up as a wrong grade, never a crash -- caught here by running the SAME
// both-directions validation this repo already uses (unchanged input must reject, a reference fix must
// accept), which is why that check belongs in this port too, not just in the original Python tooling.
// Patterns here are always matched against `norm()`-processed text, which has no embedded newlines (all
// whitespace, including \n, is collapsed to single spaces) -- so `^`/`$` without the `m` flag correctly mean
// "start/end of the whole string", exactly Python's `\A`/`\Z` semantics, with no behavior change needed
// beyond the substitution itself.
function pyPattern(p) {
  return p.replace(/\\A/g, "^").replace(/\\[Zz]/g, "$");
}

function evalBug(bug, out, files) {
  const text = scopeText(out, files, bug.file ?? null);
  if ((bug.forbid || []).some((p) => new RegExp(pyPattern(p)).test(text))) return false;
  if (bug.all && !bug.all.every((p) => new RegExp(pyPattern(p)).test(text))) return false;
  if (bug.any && !bug.any.some((p) => new RegExp(pyPattern(p)).test(text))) return false;
  if (bug.pass && !new RegExp(pyPattern(bug.pass)).test(text)) return false;
  return Boolean(bug.all || bug.any || bug.pass);
}

/** Overlay a model's emitted files onto the scenario's base files, applying the import fixup to every .ts/.tsx
 * file (base or emitted) so the merged tree is actually runnable under Node's native ESM loader. */
export function materialize(scenario, emitted, workDir) {
  const merged = { ...scenario.files, ...emitted };
  for (const [rel, rawBody] of Object.entries(merged)) {
    const body = /\.tsx?$/.test(rel) ? fixTsImports(rawBody) : rawBody;
    const full = path.join(workDir, rel);
    mkdirSync(path.dirname(full), { recursive: true });
    writeFileSync(full, body);
  }
}

/** Run the scenario's oracle (benchmarks/oracle/<id>/test/) against a materialized directory. Returns
 * {ok, output}. A non-zero exit with no "FAIL <key>:" line at all is the crash case -- callers must treat that
 * as every oracle-covered bug failing, never as a clean pass (a real bug this exact port fixed once already:
 * a crash with no structured verdict must never look identical to zero failures). */
function runOracle(scenarioId, oracleRoot, workDir) {
  const testSrc = path.join(oracleRoot, scenarioId, "test", "run.mjs");
  if (!existsSync(testSrc)) throw new Error(`no oracle defined for ${scenarioId} (expected ${testSrc})`);
  const testDst = path.join(workDir, "test", "run.mjs");
  mkdirSync(path.dirname(testDst), { recursive: true });
  writeFileSync(testDst, readFileSync(testSrc));
  try {
    const out = execFileSync("node", ["--experimental-strip-types", "test/run.mjs"], {
      cwd: workDir, encoding: "utf8", timeout: 60_000, stdio: ["ignore", "pipe", "pipe"],
    });
    return { ok: true, output: out };
  } catch (e) {
    const output = `${e.stdout || ""}${e.stderr || ""}`;
    return { ok: false, output };
  }
}

/** Grade every bug in a scenario, in a fresh temp directory that is always cleaned up. A bug with
 * `"oracle": true` is decided by actually running the code; every other bug uses the file-scoped pattern
 * rules. Mirrors grade_lib.py's merge exactly. */
export function grade(scenario, rawOutput, oracleRoot, scratchDir) {
  const oracleKeys = new Set(scenario.bugs.filter((b) => b.oracle).map((b) => b.key));
  let failedKeys = new Set();

  if (oracleKeys.size > 0) {
    const emitted = splitFiles(rawOutput);
    const work = path.join(scratchDir, `grade_${scenario.id}_${process.pid}_${Date.now()}`);
    mkdirSync(work, { recursive: true });
    try {
      materialize(scenario, emitted, work);
      const { ok, output } = runOracle(scenario.id, oracleRoot, work);
      for (const line of output.split("\n")) {
        if (line.startsWith("FAIL ")) {
          const key = line.slice(5).split(":")[0].split(" ")[0].trim();
          failedKeys.add(key);
        }
      }
      if (!ok && failedKeys.size === 0) failedKeys = new Set(oracleKeys); // crash: fail closed, not open
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  }

  const files = splitFiles(rawOutput);
  return scenario.bugs.map((b) => ({
    key: b.key,
    label: b.label,
    pass: b.oracle ? !failedKeys.has(b.key) : evalBug(b, rawOutput, files),
  }));
}
