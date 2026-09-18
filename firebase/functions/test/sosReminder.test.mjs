// Unit test for the SOS reminder decisions (pure logic, no emulator).
// `npm test` builds first, then runs this against lib/.

import { it } from "node:test";
import assert from "node:assert/strict";
import { remainingRecipients, shouldContinue, validTask } from "../lib/sosReminder.js";

const A = "uid_alice"; // sender
const B = "uid_bob";
const C = "uid_carol";

it("nobody acked -> everyone but the sender", () => {
  assert.deepEqual(remainingRecipients([A, B, C], A, []), [B, C]);
});

it("acked members are dropped", () => {
  assert.deepEqual(remainingRecipients([A, B, C], A, [B]), [C]);
});

it("everyone acked -> empty", () => {
  assert.deepEqual(remainingRecipients([A, B, C], A, [C, B]), []);
});

it("sender is excluded even without an ack, and their own ack changes nothing", () => {
  assert.deepEqual(remainingRecipients([A, B], A, [A]), [B]);
});

it("ack from someone who is not (or no longer) a member is ignored", () => {
  assert.deepEqual(remainingRecipients([A, B], A, ["uid_gone"]), [B]);
});

it("sender alone in the family / empty family -> empty", () => {
  assert.deepEqual(remainingRecipients([A], A, []), []);
  assert.deepEqual(remainingRecipients([], A, []), []);
});

it("duplicate member uids are returned once", () => {
  assert.deepEqual(remainingRecipients([B, A, B, C], A, []), [B, C]);
});

it("shouldContinue: first push (0) and reminders 1-8 continue while someone remains", () => {
  for (let attempt = 0; attempt <= 8; attempt++) assert.equal(shouldContinue(attempt, 1), true);
});

it("shouldContinue: reminder 9 is the last", () => {
  assert.equal(shouldContinue(9, 3), false);
  assert.equal(shouldContinue(10, 3), false);
});

it("shouldContinue: nobody remaining stops at any attempt", () => {
  assert.equal(shouldContinue(0, 0), false);
  assert.equal(shouldContinue(4, 0), false);
});

it("validTask accepts attempts 1-9 and rejects anything else", () => {
  const t = { familyId: "f", messageId: "m", senderUid: A, attempt: 1 };
  assert.equal(validTask(t), true);
  assert.equal(validTask({ ...t, attempt: 9 }), true);
  assert.equal(validTask({ ...t, attempt: 0 }), false);
  assert.equal(validTask({ ...t, attempt: 10 }), false);
  assert.equal(validTask({ ...t, attempt: 1.5 }), false);
  assert.equal(validTask({ ...t, attempt: "1" }), false);
  assert.equal(validTask({ ...t, messageId: "" }), false);
  assert.equal(validTask({ familyId: "f", messageId: "m", attempt: 1 }), false);
  assert.equal(validTask(null), false);
  assert.equal(validTask(undefined), false);
});
