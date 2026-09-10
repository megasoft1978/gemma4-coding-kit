// Executable oracle for permissions-cache, covering all four bugs: A (cache key ignores resourceId,
// leaking one resource's decision onto another), B (revoke doesn't invalidate the cache), C (audit log
// records the requested level instead of the actually-granted level), D (LRU evicts the wrong entry).
//
// Run: node --experimental-strip-types test/run.mjs   (cwd = the working copy of this scenario)

let failures = 0;
function fail(msg) {
  console.error("FAIL " + msg);
  failures++;
}

let grantAccess, revokeAccess, checkAccess, resetStoreForTest;
let cacheSet, cacheGet, cacheResetForTest, cacheSizeForTest, cacheKeysForTest;
let handleResourceRequest;
let getAuditLog, auditResetForTest;
try {
  ({ grantAccess, revokeAccess, checkAccess, resetStoreForTest } = await import("../server/permissions/service.ts"));
  ({
    set: cacheSet, get: cacheGet, resetForTest: cacheResetForTest,
    sizeForTest: cacheSizeForTest, keysForTest: cacheKeysForTest,
  } = await import("../server/permissions/cache.ts"));
  ({ handleResourceRequest } = await import("../server/routes/resource.ts"));
  ({ getLog: getAuditLog, resetForTest: auditResetForTest } = await import("../server/audit/logger.ts"));
} catch (e) {
  fail(`A/B/C/D: could not import server/permissions/{service,cache}.ts, server/routes/resource.ts, or server/audit/logger.ts: ${e.message}`);
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}

// --- A: cache key must include the resource, not just the user -----------------------------------------
resetStoreForTest();
grantAccess("u1", "resA", "read");
grantAccess("u1", "resB", "write");
{
  const a = checkAccess("u1", "resA"); // populates the cache first
  const b = checkAccess("u1", "resB"); // different resource, same user -- must not reuse resA's cached decision
  if (a !== "read") fail(`A: setup expected u1/resA to be "read", got "${a}"`);
  if (b !== "write") fail(`A: u1/resB returned "${b}" instead of its own granted level "write" -- looks like the cache key is missing the resource id, so it served resA's cached decision`);
}

// --- B: revoking access must invalidate any cached decision ---------------------------------------------
resetStoreForTest();
grantAccess("u2", "resC", "read");
checkAccess("u2", "resC"); // warm the cache
revokeAccess("u2", "resC");
{
  const level = checkAccess("u2", "resC");
  if (level !== "none") fail(`B: after revokeAccess, checkAccess returned "${level}" instead of "none" -- the cache was not invalidated on revoke`);
}

// --- C: the audit trail must record what was actually granted, not what was requested -------------------
resetStoreForTest();
auditResetForTest();
grantAccess("u3", "resD", "read");
{
  const result = handleResourceRequest("u3", "resD", "write"); // asking for more than was granted
  if (result.ok !== false) fail(`C: setup expected the write request to be denied (only "read" was granted), got ok=${result.ok}`);
  const entries = getAuditLog().filter((e) => e.userId === "u3" && e.resourceId === "resD");
  const entry = entries[entries.length - 1];
  if (!entry) fail("C: no audit entry recorded for the denied request");
  else if (entry.granted !== "read") {
    fail(`C: audit entry recorded granted="${entry.granted}" but the actual granted level was "read" -- looks like it logged the requested level instead of the decision`);
  }
}

// --- D: LRU eviction must drop the least-recently-used entry, not the one just inserted -----------------
cacheResetForTest();
cacheSet("uA", "r", "read");
cacheSet("uB", "r", "read");
cacheSet("uC", "r", "read"); // cache is now at capacity (3)
cacheGet("uA", "r"); // touch uA -- it is now the most-recently-used, uB is now the least-recently-used
cacheSet("uD", "r", "read"); // over capacity -- must evict uB, not uD itself
{
  const keys = cacheKeysForTest();
  const dPresent = cacheGet("uD", "r") !== undefined;
  const bPresent = cacheGet("uB", "r") !== undefined;
  if (!dPresent) {
    fail(`D: the entry just inserted (uD) was evicted immediately -- eviction appears to drop the most-recently-used end instead of the least-recently-used end. Cache keys: [${keys.join(", ")}]`);
  } else if (bPresent) {
    fail(`D: uB (least recently used) should have been evicted but is still present. Cache keys: [${keys.join(", ")}]`);
  } else if (cacheSizeForTest() > 3) {
    fail(`D: cache grew past its capacity of 3 (size=${cacheSizeForTest()})`);
  }
}

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("PERMISSIONS-CACHE OK");
process.exit(0);
