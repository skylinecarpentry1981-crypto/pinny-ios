/**
 * Family Pass — Stage 7 (docs/STAGE-7-CONTRACT.md §2).
 *
 *  redeemFamilyPass       callable  { jws }              -> verify Apple's signed transaction, bind it to the caller
 *  appStoreNotifications  HTTPS     App Store Server Notifications V2: REFUND / REVOKE remove the pass
 *
 * The client never writes users/{uid}.pass (rules deny it); these two functions
 * are the only writers of users/{uid}.pass and passes/{transactionId}.
 *
 * Verification is offline: Apple's public root certificates in ../certs are the
 * trust anchors (see certs/README.md), `enableOnlineChecks` is false, so no
 * request to Apple is ever made. Sandbox and Production transactions are both
 * accepted; the environment is read from the payload and then enforced by the
 * verifier against the signature.
 *
 * Pure helpers (isValidPassTransaction, passUpdateForNotification) are
 * unit-tested in test/pass.test.mjs against the compiled lib/pass.js.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { FieldValue, Firestore, getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";
import {
  Environment,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import type {
  JWSTransactionDecodedPayload,
  ResponseBodyV2DecodedPayload,
} from "@apple/app-store-server-library";

export const PASS_PRODUCT_ID = "com.skyline.pinny.familypass";
const BUNDLE_ID = "com.skyline.pinny";
const REGION = "australia-southeast1";
const MAX_JWS_LENGTH = 32 * 1024; // Apple JWS payloads are a few KB

/** passes/{transactionId} — one Apple transaction, one account. */
interface PassDoc {
  uid: string;
  productId: string;
  redeemedAt: FirebaseFirestore.Timestamp;
}

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested)
// ---------------------------------------------------------------------------

/** The slice of a decoded transaction the decision needs. */
export interface PassTransaction {
  productId?: string;
  type?: string;
  revocationDate?: number | null;
}

/**
 * True when a verified transaction grants a Family Pass: our non-consumable
 * product, not refunded / revoked (Apple sets revocationDate on both).
 */
export function isValidPassTransaction(t: PassTransaction): boolean {
  return t.productId === PASS_PRODUCT_ID && t.type === "Non-Consumable" && t.revocationDate == null;
}

/**
 * What a V2 notification does to a pass. REFUND and REVOKE remove it;
 * everything else (CONSUMPTION_REQUEST, TEST, subscription events, ...) is
 * acknowledged and ignored. No subtype changes the outcome today (REFUND and
 * REVOKE carry none); it is part of the signature so the caller logs it.
 */
export function passUpdateForNotification(
  type: string | undefined,
  subtype?: string,
): "revoke" | "ignore" {
  void subtype;
  return type === "REFUND" || type === "REVOKE" ? "revoke" : "ignore";
}

// ---------------------------------------------------------------------------
// Verifier
// ---------------------------------------------------------------------------

const CERT_FILES = ["AppleIncRootCertificate.cer", "AppleRootCA-G2.cer", "AppleRootCA-G3.cer"];

/**
 * SignedDataVerifier refuses a Production verifier without appAppleId. The
 * numeric App Store id only exists once the App Store Connect record does, so
 * when APP_APPLE_ID is unset we pass a placeholder and skip that one
 * comparison (only verifyNotification uses it; verifyAndDecodeTransaction
 * never does). Signature chain, bundle id and environment are always checked.
 */
class PassVerifier extends SignedDataVerifier {
  private readonly checkAppAppleId: boolean;

  constructor(roots: Buffer[], environment: Environment, appAppleId: number | undefined) {
    super(roots, false, environment, BUNDLE_ID, appAppleId ?? (environment === Environment.PRODUCTION ? 0 : undefined));
    this.checkAppAppleId = appAppleId !== undefined;
    if (!this.checkAppAppleId && environment === Environment.PRODUCTION) {
      logger.warn("APP_APPLE_ID not set: appAppleId is not checked on Production notifications");
    }
  }

  protected override verifyNotification(bundleId?: string, appAppleId?: number, environment?: string): void {
    if (this.checkAppAppleId) {
      super.verifyNotification(bundleId, appAppleId, environment);
      return;
    }
    if (this.bundleId !== bundleId) throw new VerificationException(VerificationStatus.INVALID_APP_IDENTIFIER);
    if (this.environment !== environment) throw new VerificationException(VerificationStatus.INVALID_ENVIRONMENT);
  }
}

const verifiers = new Map<Environment, PassVerifier>();

function verifierFor(environment: Environment): PassVerifier {
  let v = verifiers.get(environment);
  if (!v) {
    const roots = CERT_FILES.map((f) => readFileSync(join(__dirname, "..", "certs", f)));
    v = new PassVerifier(roots, environment, appAppleIdFromEnv());
    verifiers.set(environment, v);
  }
  return v;
}

function appAppleIdFromEnv(): number | undefined {
  const raw = process.env.APP_APPLE_ID;
  if (!raw) return undefined;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    logger.warn("APP_APPLE_ID is not a positive integer; ignoring it");
    return undefined;
  }
  return n;
}

/** Only the two App Store environments; Xcode / LocalTesting payloads are unsigned and rejected. */
function environmentOf(value: unknown): Environment | null {
  if (value === Environment.SANDBOX) return Environment.SANDBOX;
  if (value === Environment.PRODUCTION) return Environment.PRODUCTION;
  return null;
}

/**
 * The JWS payload before verification — used only to pick the environment
 * the verifier then enforces against the signature. Never trusted for
 * anything else.
 */
function unverifiedClaims(jws: string): Record<string, unknown> | null {
  const parts = jws.split(".");
  if (parts.length !== 3) return null;
  try {
    const claims: unknown = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    return claims !== null && typeof claims === "object" ? (claims as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function verificationStatus(e: unknown): string {
  return e instanceof VerificationException ? VerificationStatus[e.status] : "UNKNOWN";
}

// ---------------------------------------------------------------------------
// redeemFamilyPass — callable, { jws: transaction.jwsRepresentation }
// Buy and Restore both call this. Failures are specific HttpsError codes:
//   unauthenticated      not signed in
//   invalid-argument     missing / unreadable / unverifiable JWS
//   failed-precondition  verified, but not an active Family Pass (wrong product, refunded)
//   already-exists       this transaction is bound to another account
// ---------------------------------------------------------------------------

export const redeemFamilyPass = onCall({ region: REGION, enforceAppCheck: false }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to redeem a purchase.");

  const jws: unknown = (request.data as { jws?: unknown } | null)?.jws;
  if (typeof jws !== "string" || jws.length === 0 || jws.length > MAX_JWS_LENGTH) {
    throw new HttpsError("invalid-argument", "Missing purchase data.");
  }
  const environment = environmentOf(unverifiedClaims(jws)?.environment);
  if (!environment) throw new HttpsError("invalid-argument", "Purchase data isn't readable.");

  let tx: JWSTransactionDecodedPayload;
  try {
    tx = await verifierFor(environment).verifyAndDecodeTransaction(jws);
  } catch (e) {
    logger.warn("pass: verification failed", { uid, environment, status: verificationStatus(e) });
    throw new HttpsError("invalid-argument", "Couldn't verify the purchase.");
  }

  const transactionId = tx.transactionId;
  if (!transactionId || !isValidPassTransaction(tx)) {
    logger.warn("pass: not a valid pass transaction", {
      uid,
      environment,
      productId: tx.productId,
      type: tx.type,
      revoked: tx.revocationDate != null,
    });
    throw new HttpsError("failed-precondition", "This purchase isn't an active Family Pass.");
  }

  const db = getFirestore();
  const restored = await db.runTransaction(async (t) => {
    const passRef = db.doc(`passes/${transactionId}`);
    const snap = await t.get(passRef);
    const owner = (snap.data() as PassDoc | undefined)?.uid;
    if (owner !== undefined && owner !== uid) {
      throw new HttpsError("already-exists", "This purchase is already used by another account.");
    }
    if (!snap.exists) {
      t.set(passRef, { uid, productId: PASS_PRODUCT_ID, redeemedAt: FieldValue.serverTimestamp() });
    }
    // merge: the profile always exists after sign-in; merge keeps every other field.
    t.set(
      db.doc(`users/${uid}`),
      { pass: { transactionId, productId: PASS_PRODUCT_ID, verifiedAt: FieldValue.serverTimestamp() } },
      { merge: true },
    );
    return snap.exists;
  });

  logger.info("pass redeemed", { uid, transactionId, environment, restored });
  return { ok: true };
});

// ---------------------------------------------------------------------------
// appStoreNotifications — App Store Server Notifications V2 (HTTPS POST)
// Body: { signedPayload }. 200 for every verified notification (handled or
// ignored), 400 for a bad signature / unreadable body, so Apple retries only
// what it should. Logs carry ids and types, never the payloads.
// ---------------------------------------------------------------------------

export const appStoreNotifications = onRequest({ region: REGION }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).send("POST only");
    return;
  }
  const signedPayload: unknown = (req.body as { signedPayload?: unknown } | undefined)?.signedPayload;
  if (typeof signedPayload !== "string" || signedPayload.length === 0 || signedPayload.length > MAX_JWS_LENGTH) {
    res.status(400).send("Missing signedPayload");
    return;
  }
  const data = unverifiedClaims(signedPayload)?.data as { environment?: unknown } | undefined;
  const environment = environmentOf(data?.environment);
  if (!environment) {
    res.status(400).send("Unsupported payload");
    return;
  }

  let n: ResponseBodyV2DecodedPayload;
  try {
    n = await verifierFor(environment).verifyAndDecodeNotification(signedPayload);
  } catch (e) {
    logger.warn("app store notification: bad signature", { environment, status: verificationStatus(e) });
    res.status(400).send("Bad signature");
    return;
  }

  const action = passUpdateForNotification(n.notificationType, n.subtype);
  logger.info("app store notification", {
    type: n.notificationType,
    subtype: n.subtype,
    environment,
    action,
    notificationUUID: n.notificationUUID,
  });
  if (action === "ignore") {
    res.status(200).send("OK");
    return;
  }

  const signedTransactionInfo = n.data?.signedTransactionInfo;
  if (!signedTransactionInfo) {
    logger.warn("app store notification: no transaction info", { type: n.notificationType });
    res.status(200).send("OK");
    return;
  }
  let tx: JWSTransactionDecodedPayload;
  try {
    tx = await verifierFor(environment).verifyAndDecodeTransaction(signedTransactionInfo);
  } catch (e) {
    logger.warn("app store notification: bad transaction signature", { environment, status: verificationStatus(e) });
    res.status(400).send("Bad signature");
    return;
  }
  if (tx.productId === PASS_PRODUCT_ID && tx.transactionId) {
    const outcome = await revokePass(getFirestore(), tx.transactionId);
    logger.info("pass revoked", { transactionId: tx.transactionId, type: n.notificationType, outcome });
  }
  res.status(200).send("OK");
});

/**
 * Delete passes/{transactionId} and the users/{uid}.pass that points at it.
 * A pass re-redeemed with a newer transaction is left alone. Idempotent.
 */
async function revokePass(db: Firestore, transactionId: string): Promise<"revoked" | "pass-only" | "none"> {
  return db.runTransaction(async (t) => {
    const passRef = db.doc(`passes/${transactionId}`);
    const passSnap = await t.get(passRef);
    if (!passSnap.exists) return "none";
    const { uid } = passSnap.data() as PassDoc;
    const userRef = db.doc(`users/${uid}`);
    const userSnap = await t.get(userRef);
    const current = (userSnap.data() as { pass?: { transactionId?: string } } | undefined)?.pass;

    t.delete(passRef);
    if (userSnap.exists && current?.transactionId === transactionId) {
      t.update(userRef, { pass: FieldValue.delete() });
      return "revoked";
    }
    return "pass-only";
  });
}
