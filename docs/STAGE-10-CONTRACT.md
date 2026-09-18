# Stage 10 — "Ask location" (ping)

Owner request (2026-09-19): a button to ask a family member where they are. No background tracking: the member taps the notification, the app opens and shares once.

## Data
`families/{familyId}/pings/{pingId}` = `{ fromUid, fromName, toUid, createdAt: serverTimestamp }` (exactly these keys).
- Create: caller is a member, `fromUid == auth uid`, `toUid != fromUid`, `toUid` is in the family's `members`, `fromName` string 1–40 (UTF-16), `createdAt == request.time`.
- Read: family members. No update/delete from clients. The server deletes the ping after handling it.

## Server
`onPingCreated` (2nd gen, `families/{familyId}/pings/{pingId}` created):
- Rate limit: skip the push if the same `fromUid → toUid` pair was pushed less than 60 s ago (keep the timestamp in `families/{familyId}/pingState/{fromUid}_{toUid}` = `{ at }`, server-only, denied to clients).
- Push to `toUid` only (token from `pushTokens/{toUid}`): title `{fromName} is asking where you are`, body `Tap to share your location.`, default sound, apns-priority 10, no time-sensitive level; data `{ type: "ping", uid: fromUid, familyId }`.
- Always delete the ping doc afterwards. `purgeFamily` also removes `pings` and `pingState`.
- Pure helper `shouldSendPing(lastAtMillis, nowMillis)` unit-tested.

## Client
- Drawer row actions for other members (with or without a location): add **Ask location** (SF Symbol `location.magnifyingglass`). Order: Open in Maps · Ask location · Message. My own row is unchanged.
- Tap → write the ping in a write-only transaction (never queued offline); success → a status capsule text `Asked {firstName}` for 2 s + light haptic; the button is disabled for 60 s for that member (in-memory); failure → ErrorBanner with `error.userMessage` (offline string when offline; otherwise "Couldn't ask {firstName}. Try again.").
- Receiving: `PushRoute` handles `type == "ping"`: open the Map tab and share once with `share(source: .manual)` (not throttled). Foreground presentation `[.banner, .sound, .list]`; when the app is already active and a ping arrives, share immediately as well (the user sees the banner).
- VoiceOver: button label `Ask {firstName} for their location`.
- No new permissions, iOS 16, no background-location APIs.
