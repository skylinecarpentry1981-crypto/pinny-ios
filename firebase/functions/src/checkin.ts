/**
 * Check-in push decision for onLocationUpdated.
 *
 * Kept pure (no firebase-admin initialisation) so it can be unit-tested:
 * test/checkin.test.mjs runs against the compiled lib/checkin.js.
 */

export const CHECKIN_DEBOUNCE_MS = 10 * 60 * 1000; // 10 minutes

/** The slice of users/{uid} the decision needs (UserDoc satisfies it). */
export interface CheckInUser {
  familyId?: string | null;
  lastLocation?: { updatedAt: { toMillis(): number }; src?: string } | null;
}

/**
 * True when the update is a location share the family should hear about:
 *   - no lastLocation after the write, or no family  -> false
 *   - lastLocation.src == "sos" (SOS sends its own push) -> false
 *   - first share ever (no lastLocation before)      -> true
 *   - lastLocation.updatedAt moved forward >= 10 min -> true, else false
 *
 * src "open", "manual" and absent (legacy clients) all take the normal path.
 *
 * Writes that don't touch lastLocation (name, fcmToken, notifyOnCheckIn)
 * leave updatedAt unchanged, so the gap is 0 and nothing is sent.
 * updatedAt is always server time (rules require serverTimestamp()), so the
 * client clock cannot skew the gap. The debounce is measured from the
 * previous share, not the previous push: opening the app every few minutes
 * sends one push, then none until the member has been away for 10 min.
 */
export function shouldNotifyCheckIn(
  before: CheckInUser | undefined,
  after: CheckInUser | undefined,
): boolean {
  const next = after?.lastLocation?.updatedAt;
  if (!next || !after?.familyId) return false;
  if (after.lastLocation?.src === "sos") return false;

  const prev = before?.lastLocation?.updatedAt;
  if (!prev) return true;

  return next.toMillis() - prev.toMillis() >= CHECKIN_DEBOUNCE_MS;
}
