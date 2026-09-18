# Stage 9 — SOS keeps alerting until acknowledged

Owner request (2026-09-18): the SOS siren stopped after a few seconds; it should keep going until the receiver turns it off.
iOS limits one notification sound to 30 s and forbids endless sounds, so: a 29 s siren + repeated pushes until each receiver acknowledges.

## Data
`chats/{familyId}/messages/{messageId}/acks/{uid}` = `{ at: serverTimestamp }` (exactly one key).
- Create: caller is a member of the family, `uid == request.auth.uid`, `at == request.time`. Read: family members. No update/delete from clients.
- Only meaningful for `type == "sos"` messages (rules need not check the parent type).

## Server
- `onSOSMessage`: first push as today, plus `data.messageId`. Then enqueue reminders on a task queue function `sosReminder` (2nd gen `onTaskDispatched`, region australia-southeast1): payload `{ familyId, messageId, senderUid, attempt }`, attempts 1…9, 30 s apart (≈ 5 min total).
- Each reminder: stop if the message no longer exists; recipients = family members except the sender, minus those with an ack doc, minus those without a push token; stop when none remain; otherwise send the same SOS push (same title/body rule, urgent, siren, `apns-collapse-id` = messageId so banners replace each other) and enqueue the next attempt.
- Pure helper `remainingRecipients(members, senderUid, ackedUids)` unit-tested; `shouldContinue(attempt, remaining)`.
- `purgeFamily`/recursive delete already removes subcollections.

## Client
- Acknowledge = write my ack doc. Triggers: (1) tapping an SOS push (payload has `messageId`, `familyId`); (2) app becomes active / session ready: one query `chats/{familyId}/messages` ordered by `createdAt` desc limit 20, keep `type == "sos"`, not mine, younger than 10 min, and ack each (ignore permission-denied/already-exists); (3) when the chat listener delivers such a message while the app is open.
- The sender's "SOS sent" screen adds one line: "Your family will be alerted every 30 seconds for 5 minutes, until they open Pinny."
- No new permissions. iOS 16. Writes use the existing transaction style (never queued offline).
