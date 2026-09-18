/**
 * "Ask location" (Stage 10) rate-limit decision for onPingCreated.
 *
 * Kept pure (no firebase-admin initialisation) so it can be unit-tested:
 * test/ping.test.mjs runs against the compiled lib/ping.js.
 */

/** One push per fromUid -> toUid pair per minute. */
export const PING_MIN_INTERVAL_MS = 60_000;

/**
 * True when a ping push may be sent now.
 *
 * `lastAtMillis` is when the same fromUid -> toUid pair was last pushed
 * (families/{familyId}/pingState/{fromUid}_{toUid}.at), or undefined / null
 * when it never was. The distance is absolute: a last push a few ms in the
 * future (clock skew between instances, duplicate delivery) still blocks,
 * while a wildly future value cannot lock the pair out.
 */
export function shouldSendPing(
  lastAtMillis: number | null | undefined,
  nowMillis: number,
): boolean {
  if (typeof lastAtMillis !== "number" || !Number.isFinite(lastAtMillis)) return true;
  return Math.abs(nowMillis - lastAtMillis) >= PING_MIN_INTERVAL_MS;
}
