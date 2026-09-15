/**
 * SOS push body decision for onSOSMessage (DESIGN-SPEC §13.3).
 *
 * Kept pure (no firebase-admin initialisation) so it can be unit-tested:
 * test/sos.test.mjs runs against the compiled lib/sos.js.
 */

const SOS_LOCATION_WINDOW_MS = 60 * 1000; // 60 s

/** The slice of the SOS message the decision needs (MessageDoc satisfies it). */
export interface SOSMessage {
  createdAt: { toMillis(): number };
}

/** The slice of the sender's lastLocation the decision needs. */
export interface SOSLocation {
  updatedAt: { toMillis(): number };
  src?: string;
}

/**
 * Push body for an SOS. The SOS "carried a location" when the sender's
 * lastLocation has src "sos" and was stamped no more than 60 s before the
 * message's createdAt (the client writes the location first, then the
 * message). Both are server times (rules require serverTimestamp()), so the
 * device clock cannot skew the gap. A location stamped at or after createdAt
 * (same batch, or a newer SOS) still counts: it is a fresh SOS location.
 *
 * Anything else — no location, an older SOS location, or an ordinary share
 * (src "open" / "manual" / absent) — means this SOS went out without one.
 */
export function sosBody(
  message: SOSMessage,
  senderLocation: SOSLocation | null | undefined,
): string {
  if (senderLocation?.src !== "sos") return "Location unavailable.";
  const age = message.createdAt.toMillis() - senderLocation.updatedAt.toMillis();
  return age <= SOS_LOCATION_WINDOW_MS ? "Tap to see where they are." : "Location unavailable.";
}
