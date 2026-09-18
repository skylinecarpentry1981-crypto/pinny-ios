// Unit tests for the Family Pass decisions (pure logic, no Apple calls, no emulator).
// `npm test` builds first, then runs this against lib/.

import { it } from "node:test";
import assert from "node:assert/strict";
import { PASS_PRODUCT_ID, isValidPassTransaction, passUpdateForNotification } from "../lib/pass.js";

/** A decoded JWSTransaction as Apple signs it for our pass (the fields the decision reads). */
const pass = (extra = {}) => ({
  transactionId: "2000000123456789",
  productId: PASS_PRODUCT_ID,
  type: "Non-Consumable",
  bundleId: "com.skyline.pinny",
  environment: "Sandbox",
  ...extra,
});

it("product id is com.skyline.pinny.familypass", () => {
  assert.equal(PASS_PRODUCT_ID, "com.skyline.pinny.familypass");
});

it("our non-consumable, not revoked -> valid", () => {
  assert.equal(isValidPassTransaction(pass()), true);
});

it("another product id -> invalid", () => {
  assert.equal(isValidPassTransaction(pass({ productId: "com.skyline.pinny.other" })), false);
  assert.equal(isValidPassTransaction(pass({ productId: undefined })), false);
});

it("wrong type (consumable / subscription) -> invalid", () => {
  assert.equal(isValidPassTransaction(pass({ type: "Consumable" })), false);
  assert.equal(isValidPassTransaction(pass({ type: "Auto-Renewable Subscription" })), false);
  assert.equal(isValidPassTransaction(pass({ type: undefined })), false);
});

it("revocationDate set (refund / revoke) -> invalid; null or absent -> valid", () => {
  assert.equal(isValidPassTransaction(pass({ revocationDate: 1_758_000_000_000 })), false);
  assert.equal(isValidPassTransaction(pass({ revocationDate: 0 })), false);
  assert.equal(isValidPassTransaction(pass({ revocationDate: null })), true);
});

it("REFUND and REVOKE -> revoke", () => {
  assert.equal(passUpdateForNotification("REFUND"), "revoke");
  assert.equal(passUpdateForNotification("REVOKE"), "revoke");
});

it("CONSUMPTION_REQUEST, TEST, REFUND_REVERSED, subscription events -> ignore", () => {
  for (const type of ["CONSUMPTION_REQUEST", "TEST", "REFUND_REVERSED", "REFUND_DECLINED", "SUBSCRIBED", "DID_RENEW", "ONE_TIME_CHARGE"]) {
    assert.equal(passUpdateForNotification(type), "ignore", type);
  }
});

it("unknown / missing type -> ignore; subtype never changes the outcome", () => {
  assert.equal(passUpdateForNotification(undefined), "ignore");
  assert.equal(passUpdateForNotification("SOMETHING_NEW"), "ignore");
  assert.equal(passUpdateForNotification("REFUND", "INITIAL_BUY"), "revoke");
  assert.equal(passUpdateForNotification("TEST", "SUMMARY"), "ignore");
});
