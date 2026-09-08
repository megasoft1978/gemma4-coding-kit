// Executable oracle for auth-session, covering ONLY bug A ("token expiry compares seconds against
// milliseconds"). The original bug: `payload.exp < Date.now()` compares an epoch-SECONDS value against
// epoch-MILLISECONDS, so exp is always ~1000x smaller than Date.now() and every token -- including one issued
// a moment ago -- is treated as already expired. The other four bugs in this scenario stay pattern-graded.
// Run: node --experimental-strip-types test/run.mjs   (cwd = the working copy of this scenario)

let failures = 0;
function fail(msg) {
  console.error("FAIL " + msg);
  failures++;
}

let issueToken, verifyToken;
try {
  ({ issueToken, verifyToken } = await import("../server/auth/tokens.ts"));
} catch (e) {
  fail(`A: server/auth/tokens.ts could not be imported: ${e.message}`);
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}

// A freshly issued token, verified immediately, must be valid -- this is exactly what the units bug breaks.
{
  const token = issueToken("user-1", 900);
  const payload = verifyToken(token);
  if (!payload || payload.sub !== "user-1") {
    fail(`A: a token issued moments ago with a 900s TTL was rejected as expired, got ${JSON.stringify(payload)}`);
  }
}

// A token issued with a negative TTL (already expired by construction) must still be rejected.
{
  const token = issueToken("user-2", -10);
  const payload = verifyToken(token);
  if (payload !== null) {
    fail(`A: a token issued with a -10s TTL (already expired) was accepted, got ${JSON.stringify(payload)}`);
  }
}

// A token with a long TTL (1 hour) must also validate -- guards against a fix that happens to work only for
// TTLs near zero by coincidence of unit-mismatch magnitude.
{
  const token = issueToken("user-3", 3600);
  const payload = verifyToken(token);
  if (!payload || payload.sub !== "user-3") {
    fail(`A: a token issued with a 3600s TTL was rejected as expired, got ${JSON.stringify(payload)}`);
  }
}

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("AUTH-SESSION A OK");
process.exit(0);
