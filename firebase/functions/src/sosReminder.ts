/**
 * SOS reminder decisions for onSOSMessage / sosReminder (Stage 9: the SOS
 * keeps alerting until each receiver acknowledges it).
 *
 * Kept pure (no firebase-admin initialisation) so it can be unit-tested:
 * test/sosReminder.test.mjs runs against the compiled lib/sosReminder.js.
 */

/** Reminders 1…9, 30 s apart: the family is re-alerted for about 5 minutes. */
export const SOS_REMINDER_MAX_ATTEMPTS = 9;
export const SOS_REMINDER_DELAY_SECONDS = 30;

/** Task payload of the sosReminder queue. `attempt` is the reminder's number (1…9). */
export interface SOSReminderTask {
  familyId: string;
  messageId: string;
  senderUid: string;
  attempt: number;
}

/**
 * Who still needs the alert: the family's members, minus the sender, minus
 * everyone whose ack doc (chats/{familyId}/messages/{messageId}/acks/{uid})
 * exists. Order of `members` is kept; duplicates are dropped.
 */
export function remainingRecipients(
  members: string[],
  senderUid: string,
  ackedUids: string[],
): string[] {
  const acked = new Set(ackedUids);
  return [...new Set(members)].filter((uid) => uid !== senderUid && !acked.has(uid));
}

/**
 * Whether to enqueue the reminder after `attempt` (0 = the first push from
 * onSOSMessage): only while someone is still un-acknowledged and the last
 * reminder (9) has not run yet.
 */
export function shouldContinue(attempt: number, remaining: number): boolean {
  return remaining > 0 && attempt < SOS_REMINDER_MAX_ATTEMPTS;
}

/** Runtime check of a task payload (the queue is only fed by our own functions). */
export function validTask(data: unknown): data is SOSReminderTask {
  const d = data as Partial<SOSReminderTask> | null | undefined;
  return (
    typeof d?.familyId === "string" && d.familyId.length > 0 &&
    typeof d.messageId === "string" && d.messageId.length > 0 &&
    typeof d.senderUid === "string" && d.senderUid.length > 0 &&
    Number.isInteger(d.attempt) &&
    (d.attempt as number) >= 1 && (d.attempt as number) <= SOS_REMINDER_MAX_ATTEMPTS
  );
}
