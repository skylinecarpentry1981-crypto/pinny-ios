// Unit test for the push-token de-duplication decision (pure logic, no emulator).
// `npm test` builds first, then runs this against lib/.
// Docs are pushTokens/{uid} = { token, updatedAt }.

import { it } from "node:test";
import assert from "node:assert/strict";
import { Timestamp } from "firebase-admin/firestore";
import { tokenChanged } from "../lib/token.js";

const T0 = Date.UTC(2026, 8, 15, 0, 0, 0);
const tok = (token, s = 0) => ({ token, updatedAt: Timestamp.fromMillis(T0 + s * 1000) });

it("doc created with a token -> true", () => {
  assert.equal(tokenChanged(undefined, tok("T1")), true);
});

it("token replaced (refresh) -> true", () => {
  assert.equal(tokenChanged(tok("T1"), tok("T2", 5)), true);
});

it("same token re-saved (updatedAt only) -> false", () => {
  assert.equal(tokenChanged(tok("T1"), tok("T1", 5)), false);
});

it("doc deleted -> false (sign-out, dead-token clean-up, account deletion, and the loop guard: the dedupe's own deletes)", () => {
  assert.equal(tokenChanged(tok("T1"), undefined), false);
});

it("empty or missing token -> false", () => {
  assert.equal(tokenChanged(tok("T1"), tok("")), false);
  assert.equal(tokenChanged(undefined, { updatedAt: Timestamp.fromMillis(T0) }), false);
});

it("neither side exists -> false", () => {
  assert.equal(tokenChanged(undefined, undefined), false);
});
