// Executable oracle for realtime-sync, covering bugs A ("broadcast echoes back to the sender") and D
// ("persist not awaited before ack"). Bugs B, C, E, F stay pattern-graded -- see scripts/grade_lib.py's
// per-bug merge.
//
// B ("drain() empties the queue before send is confirmed") is DELIBERATELY not covered here. Its correct
// fixes can take genuinely different API shapes: drain-without-clearing-until-confirmed, or clear-plus-a-
// separate-requeue-function are both legitimate designs, and a black-box behavioral test would have to assume
// one specific interface to observe the difference -- risking rejecting a valid solution that doesn't happen
// to match the assumed shape. It stays pattern-graded (grade_lib.py) rather than ship a fragile oracle.
//
// D needs a real async gap to be observable at all: the scenario's own server/store.ts `persist()` has no
// internal await, so an async function's body runs to completion synchronously regardless of whether the
// caller awaits it -- meaning "awaited or not" is unobservable with the original persist(). This test replaces
// server/store.ts with a version that has a genuine delay before writing, purely so the timing difference
// becomes observable; store.ts is not itself a bug file for this scenario (see the scenario's `file` scoping
// for bug D, which points at server/hub, not server/store), so this substitution doesn't affect grading of
// anything else.
//
// Run: node --experimental-strip-types test/run.mjs   (cwd = the working copy of this scenario)

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

let failures = 0;
function fail(msg) {
  console.error("FAIL " + msg);
  failures++;
}

// Give persist() a real delay before hub.ts is ever imported, so "awaited or not" becomes observable.
// Resolved relative to this script's own location, not process.cwd() -- a plain relative path passed to
// writeFileSync resolves against the CWD the process was launched with (the scenario root), not against
// test/run.mjs's own directory the way an import specifier does. Using cwd-relative "../server/store.ts"
// here silently wrote one level above the scenario root and crashed the whole oracle with ENOENT, which
// grade_lib.py's key-extraction (only understands "FAIL <key>:" lines) then read as zero failures -- turning
// a crash into a false PASS for every oracle-covered bug in the scenario. Caught by testing unchanged input.
const storeTsPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "server", "store.ts");
writeFileSync(
  storeTsPath,
  `export async function persist(edit) {
  await new Promise((r) => setTimeout(r, 30));
  history_.get(edit.docId) ?? history_.set(edit.docId, []);
  history_.get(edit.docId).push(edit);
}
const history_ = new Map();
export function history(docId) { return history_.get(docId) ?? []; }
`
);

let broadcast, join, handleEdit;
try {
  ({ broadcast, join, handleEdit } = await import("../server/hub.ts"));
} catch (e) {
  fail(`A/D: server/hub.ts could not be imported: ${e.message}`);
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}

function mockSocket() {
  const ws = { sent: [], on() {}, send(msg) { ws.sent.push(msg); } };
  return ws;
}

// --- A: broadcast must not echo back to the sender ----------------------------------------------------
{
  const sender = mockSocket();
  const other1 = mockSocket();
  const other2 = mockSocket();
  if (typeof join === "function") {
    join(sender);
    join(other1);
    join(other2);
  } else {
    fail("A: server/hub.ts no longer exports join() -- cannot verify broadcast without registering clients");
  }
  try {
    broadcast({ opId: "e1", docId: "d1", at: 0, patch: "p" }, sender);
  } catch (e) {
    fail(`A: broadcast threw: ${e.message}`);
  }
  if (sender.sent.length !== 0) {
    fail(`A: broadcast sent the edit back to the originating client (sender.sent=${JSON.stringify(sender.sent)})`);
  }
  if (other1.sent.length !== 1 || other2.sent.length !== 1) {
    fail(`A: broadcast should reach every OTHER client exactly once, got other1=${other1.sent.length} other2=${other2.sent.length}`);
  }
}

// --- D: the ack must not be sent before persist's async work has actually completed ---------------------
// A synchronous-only check is not enough: a decoy that adds an unrelated `await Promise.resolve()` after a
// fire-and-forget `persist(edit)` also suspends the function, so it would pass a check that only asks "did it
// suspend at all" -- confirmed directly, that exact decoy slipped through the first version of this test.
// Instead this checks a real MIDPOINT of persist's actual 30ms delay: if the ack has already gone out by 10ms
// in, whatever the function is waiting on, it isn't persist's own delay.
{
  const ws = mockSocket();
  const edit = { opId: "e2", docId: "d2", at: 0, patch: "p" };
  let handlePromise;
  try {
    handlePromise = handleEdit(ws, edit); // call, but do not await yet
  } catch (e) {
    fail(`D: handleEdit threw synchronously: ${e.message}`);
    handlePromise = Promise.resolve();
  }
  const sentImmediately = ws.sent.length > 0;
  await new Promise((r) => setTimeout(r, 10)); // well before persist's real 30ms delay completes
  const sentAtMidpoint = ws.sent.length > 0;
  await handlePromise;
  if (sentImmediately || sentAtMidpoint) {
    fail(
      "D: the ack was sent before persist's async work (a real 30ms delay) had actually completed -- " +
      "persist(edit) is not being awaited before the ack goes out"
    );
  }
  if (ws.sent.length === 0) {
    fail("D: no ack was ever sent for a valid edit");
  }
}

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("REALTIME-SYNC A/D OK");
process.exit(0);
