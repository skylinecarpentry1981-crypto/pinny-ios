// Unit test for the SOS push body (pure logic, no emulator).
// `npm test` builds first, then runs this against lib/.

import { it } from "node:test";
import assert from "node:assert/strict";
import { Timestamp } from "firebase-admin/firestore";
import { sosBody } from "../lib/sos.js";

const T0 = Date.UTC(2026, 8, 15, 0, 0, 0);
const SEC = 1000;
const LOCATED = "Tap to see where they are.";
const UNAVAILABLE = "Location unavailable.";

/** The stored SOS message (DESIGN-SPEC §13.3), created at T0. */
const message = {
  senderId: "uid_alice",
  senderName: "Alice",
  text: "SOS",
  type: "sos",
  createdAt: Timestamp.fromMillis(T0),
};

/** Sender's lastLocation stamped `s` seconds before the message (no src = legacy). */
const legacyLoc = (s) => ({ lat: -37.8136, lng: 144.9631, updatedAt: Timestamp.fromMillis(T0 - s * SEC) });
const loc = (s, src = "sos") => ({ ...legacyLoc(s), src });

it("fresh sos location (2 s before the message) -> tap copy", () => {
  assert.equal(sosBody(message, loc(2)), LOCATED);
});

it("sos location exactly 60 s before -> tap copy (boundary)", () => {
  assert.equal(sosBody(message, loc(60)), LOCATED);
});

it("sos location 61 s before -> unavailable", () => {
  assert.equal(sosBody(message, loc(61)), UNAVAILABLE);
});

it("fresh location with src 'open' / 'manual' / absent -> unavailable", () => {
  assert.equal(sosBody(message, loc(2, "open")), UNAVAILABLE);
  assert.equal(sosBody(message, loc(2, "manual")), UNAVAILABLE);
  assert.equal(sosBody(message, legacyLoc(2)), UNAVAILABLE);
});

it("no location (undefined / null) -> unavailable", () => {
  assert.equal(sosBody(message, undefined), UNAVAILABLE);
  assert.equal(sosBody(message, null), UNAVAILABLE);
});
