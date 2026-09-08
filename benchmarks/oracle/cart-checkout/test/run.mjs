// Executable oracle for cart-checkout, covering ONLY bug B ("tax applied before discount"). The other three
// bugs (A: in-place mutation, C: unawaited reserveStock, D: double-submit guard) stay pattern-graded via
// grade_lib.py -- see scripts/grade_lib.py's merge logic: a bug needs `"oracle": true` on ITSELF to be routed
// here, so this file only needs to print FAIL/pass lines for "B".
//
// The check is purely mathematical and reads TAX_RATE from the module under test rather than hardcoding it,
// so it doesn't care what the constant's value is -- only that discount is applied before tax, not after.
// Run: node --experimental-strip-types test/run.mjs   (cwd = the working copy of this scenario)

let failures = 0;
function fail(msg) {
  console.error("FAIL " + msg);
  failures++;
}

let priceCart, TAX_RATE;
try {
  ({ priceCart, TAX_RATE } = await import("../server/pricing.ts"));
} catch (e) {
  fail(`B: server/pricing.ts could not be imported: ${e.message}`);
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}

// These specific (subtotal, discount) pairs are not arbitrary: applying discount-then-tax and tax-then-discount
// round to the SAME final cent for most round numbers (multiplication order is commutative, and rounding at
// each step usually doesn't tip the result across a 0.5 boundary either way). These three were found by a
// brute-force search over subtotal x discount specifically because the two orderings round to DIFFERENT
// final totals for them -- so an implementation that gets the order wrong is guaranteed to fail at least one.
const cases = [
  { lines: [{ sku: "a", qty: 1, unitCents: 107 }], discount: 0.18 },  // subtotal 107c: buggy 105 vs correct 106
  { lines: [{ sku: "a", qty: 1, unitCents: 114 }], discount: 0.12 },  // subtotal 114c: buggy 121 vs correct 120
  { lines: [{ sku: "a", qty: 1, unitCents: 128 }], discount: 0.2 },   // subtotal 128c: buggy 123 vs correct 122
];

for (const { lines, discount } of cases) {
  let result;
  try {
    result = priceCart(lines, discount);
  } catch (e) {
    fail(`B: priceCart threw for ${JSON.stringify({ lines, discount })}: ${e.message}`);
    continue;
  }
  const subtotal = lines.reduce((sum, l) => sum + l.unitCents * l.qty, 0);
  // Correct order: discount the subtotal FIRST, then tax the discounted amount.
  const discounted = Math.round(subtotal * (1 - discount));
  const expectedTotal = Math.round(discounted * (1 + TAX_RATE));
  if (!result || result.total !== expectedTotal) {
    fail(
      `B: discount=${discount} on subtotal ${subtotal}c -- expected total ${expectedTotal}c ` +
      `(discount applied before tax), got ${JSON.stringify(result)}`
    );
  }
}

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("CART-CHECKOUT B OK");
process.exit(0);
