// Executable oracle for orders-dashboard, covering bugs B ("float money arithmetic") and C ("UTC vs local
// date boundary for 'today'"). The other three bugs (A: async errors, D: middleware order, E: unstable
// effect dependency) stay pattern-graded -- see scripts/grade_lib.py's per-bug merge.
//
// C needs a frozen clock: the test process runs with TZ=America/New_York (set by scripts/oracle_run.py at
// the subprocess level, not here -- Node's ICU timezone cache is not reliably re-read mid-process) and
// overrides the global Date constructor's zero-argument form so `new Date()` inside the module under test
// returns a fixed instant, without touching any other Date usage (parsing an explicit ISO string still works
// exactly as normal Date would).
//
// Run: node --experimental-strip-types test/run.mjs   (cwd = the working copy of this scenario)

let failures = 0;
function fail(msg) {
  console.error("FAIL " + msg);
  failures++;
}

// Freeze "now" to 2026-09-07T00:15:00.000Z = 2026-09-06 20:15 local (America/New_York, EDT = UTC-4).
// At this instant the UTC calendar day (Sept 7) and the local calendar day (Sept 6) genuinely differ, which
// is exactly the boundary condition the bug gets wrong.
const FIXED_NOW = new Date("2026-09-07T00:15:00.000Z");
class FixedDate extends Date {
  constructor(...args) {
    if (args.length === 0) super(FIXED_NOW.getTime());
    else super(...args);
  }
  static now() {
    return FIXED_NOW.getTime();
  }
}
globalThis.Date = FixedDate;

let computeTotal, ordersPlacedToday;
try {
  ({ computeTotal, ordersPlacedToday } = await import("../server/services/orderService.ts"));
} catch (e) {
  fail(`B/C: server/services/orderService.ts could not be imported: ${e.message}`);
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}

// --- B: float money arithmetic -------------------------------------------------------------------------
const moneyCases = [
  { lines: [{ sku: "x", unitPrice: 0.1, qty: 1 }, { sku: "y", unitPrice: 0.2, qty: 1 }], expected: 0.3 },
  { lines: [{ sku: "x", unitPrice: 1.1, qty: 3 }], expected: 3.3 },
  { lines: [{ sku: "x", unitPrice: 29.99, qty: 7 }], expected: 209.93 },
];
for (const { lines, expected } of moneyCases) {
  let result;
  try {
    result = computeTotal({ id: "probe", userId: "u", placedAt: "2026-01-01T00:00:00.000Z", lines, total: 0 });
  } catch (e) {
    fail(`B: computeTotal threw for ${JSON.stringify(lines)}: ${e.message}`);
    continue;
  }
  if (result !== expected) {
    fail(`B: ${JSON.stringify(lines)} should total exactly ${expected}, got ${result} (floating-point drift, not rounded to the cent)`);
  }
}

// --- C: UTC vs local date boundary for "today" ------------------------------------------------------------
// o1 (userId u1) is seeded at 2026-09-06T23:40:00.000Z = 2026-09-06 19:40 local -- local calendar day matches
// the frozen "now"'s local day (Sept 6), but NOT its UTC-ISO day (Sept 7). A UTC-slice implementation
// wrongly excludes it; a correct local-calendar-day implementation includes it.
{
  let result;
  try {
    result = ordersPlacedToday("u1");
  } catch (e) {
    fail(`C: ordersPlacedToday threw: ${e.message}`);
    result = [];
  }
  if (!Array.isArray(result) || !result.some((o) => o.id === "o1")) {
    fail(
      `C: at a moment where UTC-today (Sept 7) and local-today (Sept 6, America/New_York) differ, ` +
      `an order placed at local Sept 6 (o1) was excluded -- "today" is being computed from the UTC ` +
      `calendar day instead of the operator's local one. Got ${JSON.stringify(result)}`
    );
  }
}
// Sanity check in the other direction: a day with no orders must still return nothing, guarding against a
// degenerate "return everything" fix that would pass the check above for the wrong reason.
{
  const farFuture = new Date("2026-09-20T12:00:00.000Z");
  class FarFutureDate extends Date {
    constructor(...args) { if (args.length === 0) super(farFuture.getTime()); else super(...args); }
    static now() { return farFuture.getTime(); }
  }
  globalThis.Date = FarFutureDate;
  let result;
  try {
    result = ordersPlacedToday("u1");
  } catch (e) {
    fail(`C: ordersPlacedToday threw on an unrelated day: ${e.message}`);
    result = null;
  }
  if (result === null || result.length !== 0) {
    fail(`C: querying a day with no orders for u1 should return an empty array, got ${JSON.stringify(result)}`);
  }
  globalThis.Date = FixedDate; // restore, in case anything else in this file runs after
}

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("ORDERS-DASHBOARD B/C OK");
process.exit(0);
