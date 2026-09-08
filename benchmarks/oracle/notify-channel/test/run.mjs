// Executable oracle for the notify-channel scenario, replacing pattern grading with real behavior.
//
// Why this exists: notify-channel was marked "discriminating": false because every model scored 6/6 under
// the old regex rules, and an adversarial audit later found those rules scored on a bare mention of the
// requirement (e.g. "E.164" appearing in prose) rather than a working implementation. This oracle imports the
// emitted TypeScript directly (Node 24 --experimental-strip-types, zero dependencies, same convention as
// datasets/bulk_tasks/*/test/run.mjs) and calls it, so passing requires the code to actually behave correctly.
//
// One real limitation, stated rather than hidden: the Channel interface's SendResult does not return the sent
// body, so a truncated 160-char body and an un-truncated one are behaviorally IDENTICAL from outside send() --
// bug D can only be tested for "a long body is not rejected", not "the body was actually cut to 160 chars".
// That is still strictly better than the old regex, which accepted a REJECT-instead-of-truncate implementation
// as a pass (the exact false positive the 2026-09-08 audit found).
//
// Run: node --experimental-strip-types test/run.mjs   (cwd = the working copy of this scenario)
// Exit 0 = every check passed. Exit 1 = at least one FAIL line was printed.

let failures = 0;
function fail(msg) {
  console.error("FAIL " + msg);
  failures++;
}

// --- load the module under test, tolerating a model that never created sms.ts at all -----------------------
let smsChannel;
try {
  ({ smsChannel } = await import("../server/channels/sms.ts"));
} catch (e) {
  fail(`server/channels/sms.ts could not be imported: ${e.message}`);
}

let dispatch;
try {
  ({ dispatch } = await import("../server/dispatch.ts"));
} catch (e) {
  fail(`server/dispatch.ts could not be imported: ${e.message}`);
  console.error(`\n${failures} check(s) failed`);
  process.exit(1); // dispatch is required for every remaining check; no point continuing
}

// --- A: sms channel module created, implements Channel with name "sms" -------------------------------------
if (!smsChannel || smsChannel.name !== "sms" || typeof smsChannel.send !== "function") {
  fail("A: smsChannel missing, wrongly named, or has no send() method");
}

// --- B/C: E.164 validation, invalid_number returned not thrown ---------------------------------------------
// A missing smsChannel must fail every check below explicitly -- silently skipping via optional chaining
// would leave C and D with no FAIL line at all, which the grader reads as a pass (confirmed: this was a real
// bug caught by testing the empty-output case before shipping the oracle).
if (!smsChannel) {
  fail("B: smsChannel is missing, cannot test E.164 validation");
  fail("C: smsChannel is missing, cannot test invalid_number handling");
  fail("D: smsChannel is missing, cannot test the 160-char cap");
} else {
  const badNumbers = ["12345678", "+123", "+1234567890123456", "not-a-number", ""];
  for (const to of badNumbers) {
    let result;
    try {
      result = await smsChannel.send(to, "welcome", "hi");
    } catch (e) {
      fail(`C: smsChannel.send threw for invalid number ${JSON.stringify(to)} instead of returning a result: ${e.message}`);
      continue;
    }
    if (!result || result.ok !== false || result.error !== "invalid_number") {
      fail(`B: ${JSON.stringify(to)} should be rejected with error "invalid_number", got ${JSON.stringify(result)}`);
    }
  }
  const goodNumbers = ["+12345678", "+123456789012345"]; // 8 and 15 digits, the stated bounds
  for (const to of goodNumbers) {
    let result;
    try {
      result = await smsChannel.send(to, "welcome", "hi");
    } catch (e) {
      fail(`B: smsChannel.send threw for a valid E.164 number ${to}: ${e.message}`);
      continue;
    }
    if (!result || result.ok !== true || result.error === "invalid_number") {
      fail(`B: valid E.164 number ${to} was wrongly rejected, got ${JSON.stringify(result)}`);
    }
  }

  // D: 160-char cap must not be rejected (see file header for the interface limitation on this check)
  const longBody = "x".repeat(500);
  let result;
  try {
    result = await smsChannel.send("+12345678", "welcome", longBody);
  } catch (e) {
    fail(`D: smsChannel.send threw on a 500-char body instead of truncating: ${e.message}`);
  }
  if (result && result.ok !== true) {
    fail(`D: a 500-char body was rejected instead of truncated, got ${JSON.stringify(result)}`);
  }
}

// --- E: registered in dispatch CHANNELS, and email is unaffected --------------------------------------------
try {
  const smsResult = await dispatch({ to: "+12345678", channel: "sms", templateId: "welcome", vars: { name: "Ada" } });
  if (!smsResult || smsResult.error === "unknown_channel") {
    fail(`E: dispatch did not register "sms", got ${JSON.stringify(smsResult)}`);
  }
} catch (e) {
  fail(`E: dispatch threw for channel "sms": ${e.message}`);
}
try {
  const emailResult = await dispatch({ to: "a@b.com", channel: "email", templateId: "welcome", vars: { name: "Ada" } });
  if (!emailResult || emailResult.ok !== true) {
    fail(`E (regression): adding sms broke the existing email channel, got ${JSON.stringify(emailResult)}`);
  }
} catch (e) {
  fail(`E (regression): dispatch threw for channel "email" after adding sms: ${e.message}`);
}
try {
  const unknownResult = await dispatch({ to: "x", channel: "carrier-pigeon", templateId: "welcome", vars: {} });
  if (!unknownResult || unknownResult.error !== "unknown_channel") {
    fail(`E (regression): an unknown channel should still return "unknown_channel", got ${JSON.stringify(unknownResult)}`);
  }
} catch (e) {
  fail(`E (regression): dispatch threw for an unknown channel instead of returning a result: ${e.message}`);
}

// --- F: render failure returned as unknown_template result, not thrown --------------------------------------
try {
  const result = await dispatch({ to: "a@b.com", channel: "email", templateId: "does-not-exist", vars: {} });
  if (!result || result.ok !== false || result.error !== "unknown_template") {
    fail(`F: an unknown templateId should return {ok:false, error:"unknown_template"}, got ${JSON.stringify(result)}`);
  }
} catch (e) {
  fail(`F: dispatch threw for an unknown templateId instead of returning a failed result: ${e.message}`);
}

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("ALL 6 NOTIFY-CHANNEL CHECKS OK");
process.exit(0);
