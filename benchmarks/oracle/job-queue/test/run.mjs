// Executable oracle for job-queue, covering all four bugs: A (priority ignored), B (idempotency), C (linear
// not exponential backoff), D (retention keyed on createdAt instead of doneAt).
//
// Run: node --experimental-strip-types test/run.mjs   (cwd = the working copy of this scenario)

let failures = 0;
function fail(msg) {
  console.error("FAIL " + msg);
  failures++;
}

let enqueue, dequeue, markInFlight, markDone, resetForTest, pruneCompleted;
let processOnce, computeBackoffMs;
let sideEffectCounts, resetSideEffectsForTest;
try {
  ({ enqueue, dequeue, markInFlight, markDone, resetForTest, pruneCompleted } =
    await import("../server/queue.ts"));
  ({ processOnce, computeBackoffMs } = await import("../server/worker.ts"));
  ({ sideEffectCounts, resetSideEffectsForTest } = await import("../server/jobs/handlers.ts"));
} catch (e) {
  fail(`A/B/C/D: could not import server/queue.ts, server/worker.ts, or server/jobs/handlers.ts: ${e.message}`);
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}

// --- A: priority ordering -------------------------------------------------------------------------------
resetForTest();
enqueue("low", {}, 1);
const hi = enqueue("high", {}, 10);
{
  const first = dequeue();
  if (!first || first.id !== hi.id) {
    fail(`A: expected the priority-10 job dequeued first, got ${first ? `${first.id} (priority ${first.priority})` : "undefined"}`);
  }
}
// Tie-break sanity: equal priority must fall back to insertion order, not become nondeterministic or reverse.
resetForTest();
const tieA = enqueue("tieA", {}, 5);
const tieB = enqueue("tieB", {}, 5);
{
  const first = dequeue();
  if (!first || first.id !== tieA.id) {
    fail(`A: two jobs with equal priority should dequeue in insertion order (${tieA.id} before ${tieB.id}), got ${first ? first.id : "undefined"}`);
  }
}

// --- B: idempotency ---------------------------------------------------------------------------------------
resetForTest();
resetSideEffectsForTest();
{
  const job = enqueue("normal", {});
  await processOnce(job.id);
  await processOnce(job.id); // job already done -- must be a safe no-op, not a repeat of the side effect
  const count = sideEffectCounts[job.id] ?? 0;
  if (count !== 1) {
    fail(`B: side effect ran ${count} time(s) for a job processed twice after it already completed, expected exactly 1`);
  }
}

// --- C: exponential backoff -------------------------------------------------------------------------------
{
  const d1 = computeBackoffMs(1);
  const d2 = computeBackoffMs(2);
  const d3 = computeBackoffMs(3);
  // Exponential growth roughly doubles each step; a linear "fix" (bigger base delay, same +delay per attempt)
  // must still fail this, which is exactly the case a plausible-looking non-fix produces.
  if (!(d2 >= d1 * 1.9 && d3 >= d2 * 1.9)) {
    fail(`C: backoff does not grow exponentially -- attempt1=${d1}ms attempt2=${d2}ms attempt3=${d3}ms (expected roughly doubling each step)`);
  }
}

// --- D: retention keyed on completion time, not enqueue time ------------------------------------------------
resetForTest();
{
  // A job that sat in the queue a long time (enqueued 48h ago) but just completed: must NOT be pruned yet,
  // since its retention window (24h) is measured from completion, not from when it was first enqueued.
  const slowButRecent = enqueue("slow", {});
  slowButRecent.createdAt = Date.now() - 48 * 60 * 60 * 1000;
  markInFlight(slowButRecent.id);
  markDone(slowButRecent.id); // doneAt = now
  const prunedTooSoon = pruneCompleted(Date.now());
  if (prunedTooSoon !== 0) {
    fail(`D: a job completed just now was pruned (${prunedTooSoon} pruned) even though completion was recent -- retention appears keyed on enqueue time, not completion time`);
  }
}
resetForTest();
{
  // Sanity check in the other direction: a job that completed long ago (regardless of when it was enqueued)
  // must eventually be pruned, guarding against a degenerate "never prune anything" fix.
  const oldCompleted = enqueue("fast", {});
  markInFlight(oldCompleted.id);
  markDone(oldCompleted.id);
  oldCompleted.doneAt = Date.now() - 25 * 60 * 60 * 1000; // completed 25h ago, past the 24h retention window
  const prunedEventually = pruneCompleted(Date.now());
  if (prunedEventually !== 1) {
    fail(`D: a job completed 25h ago should have been pruned (24h retention), got prunedCount=${prunedEventually}`);
  }
}

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("JOB-QUEUE OK");
process.exit(0);
