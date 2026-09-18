// Unit test for the "Ask location" rate limit (pure logic, no emulator).
// `npm test` builds first, then runs this against lib/.

import { it } from "node:test";
import assert from "node:assert/strict";
import { PING_MIN_INTERVAL_MS, shouldSendPing } from "../lib/ping.js";

const NOW = Date.UTC(2026, 8, 19, 0, 0, 0);

it("the interval is 60 s", () => {
  assert.equal(PING_MIN_INTERVAL_MS, 60_000);
});

it("never pushed before -> send", () => {
  assert.equal(shouldSendPing(undefined, NOW), true);
  assert.equal(shouldSendPing(null, NOW), true);
});

it("pushed 1 s / 59.999 s ago -> skip", () => {
  assert.equal(shouldSendPing(NOW - 1000, NOW), false);
  assert.equal(shouldSendPing(NOW - 59_999, NOW), false);
});

it("pushed at the same millisecond (duplicate delivery) -> skip", () => {
  assert.equal(shouldSendPing(NOW, NOW), false);
});

it("pushed exactly 60 s ago or earlier -> send", () => {
  assert.equal(shouldSendPing(NOW - 60_000, NOW), true);
  assert.equal(shouldSendPing(NOW - 3_600_000, NOW), true);
});

it("last push a few ms in the future (clock skew between instances) -> skip", () => {
  assert.equal(shouldSendPing(NOW + 5, NOW), false);
});

it("last push 60 s or more in the future -> send, never locks the pair out", () => {
  assert.equal(shouldSendPing(NOW + 60_000, NOW), true);
});

it("garbage timestamp -> send", () => {
  assert.equal(shouldSendPing(Number.NaN, NOW), true);
  assert.equal(shouldSendPing("yesterday", NOW), true);
});
