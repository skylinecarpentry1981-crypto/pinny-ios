// Unit test for the check-in push decision (pure logic, no emulator).
// `npm test` = `npm run build && node --test test/checkin.test.mjs test/places.test.mjs test/sos.test.mjs test/token.test.mjs` — runs against lib/.

import { it } from "node:test";
import assert from "node:assert/strict";
import { Timestamp } from "firebase-admin/firestore";
import { shouldNotifyCheckIn } from "../lib/checkin.js";

const T0 = Date.UTC(2026, 8, 15, 0, 0, 0);
const MIN = 60 * 1000;

/** lastLocation shared `m` minutes after T0 (a fresh Timestamp each call, like a real snapshot). */
const loc = (m) => ({ lat: -37.8136, lng: 144.9631, updatedAt: Timestamp.fromMillis(T0 + m * MIN) });
const user = (extra = {}) => ({ name: "Alice", familyId: "familyA", notifyOnCheckIn: true, ...extra });

it("first share ever -> true", () => {
  assert.equal(shouldNotifyCheckIn(user(), user({ lastLocation: loc(0) })), true);
});

it("3 min after previous share -> false", () => {
  assert.equal(shouldNotifyCheckIn(user({ lastLocation: loc(0) }), user({ lastLocation: loc(3) })), false);
});

it("15 min after previous share -> true", () => {
  assert.equal(shouldNotifyCheckIn(user({ lastLocation: loc(0) }), user({ lastLocation: loc(15) })), true);
});

it("non-location update (name / fcmToken) -> false", () => {
  const before = user({ lastLocation: loc(0) });
  assert.equal(shouldNotifyCheckIn(before, user({ name: "Alice B", lastLocation: loc(0) })), false);
  assert.equal(shouldNotifyCheckIn(before, user({ fcmToken: "t", lastLocation: loc(0) })), false);
});

it("missing after.lastLocation -> false", () => {
  assert.equal(shouldNotifyCheckIn(user({ lastLocation: loc(0) }), user()), false);
  assert.equal(shouldNotifyCheckIn(user(), user({ lastLocation: null })), false);
});

it("no familyId -> false (never queries users with an undefined familyId)", () => {
  assert.equal(shouldNotifyCheckIn(user({ familyId: null }), user({ familyId: null, lastLocation: loc(0) })), false);
});

// Stage 3.6 — lastLocation.src. SOS has its own push, so no check-in push.
const locSrc = (m, src) => ({ ...loc(m), src });

it("src 'sos' -> false (first share and 15 min later)", () => {
  assert.equal(shouldNotifyCheckIn(user(), user({ lastLocation: locSrc(0, "sos") })), false);
  assert.equal(shouldNotifyCheckIn(user({ lastLocation: loc(0) }), user({ lastLocation: locSrc(15, "sos") })), false);
});

it("src 'open' / 'manual' / absent 15 min later -> true", () => {
  const before = user({ lastLocation: loc(0) });
  assert.equal(shouldNotifyCheckIn(before, user({ lastLocation: locSrc(15, "open") })), true);
  assert.equal(shouldNotifyCheckIn(before, user({ lastLocation: locSrc(15, "manual") })), true);
  assert.equal(shouldNotifyCheckIn(before, user({ lastLocation: loc(15) })), true);
});

it("src 'open' 3 min later -> false (debounce unchanged)", () => {
  assert.equal(shouldNotifyCheckIn(user({ lastLocation: loc(0) }), user({ lastLocation: locSrc(3, "open") })), false);
});
