# Critical Alerts entitlement — request pack

Critical Alerts let the SOS notification play its sound even when the iPhone is muted or in a Focus mode.
Apple grants the entitlement per app, on request. Until it is granted, the app must NOT contain the entitlement (signing would fail).

## 1. Where to apply (owner, Account Holder)

https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/

## 2. Form answers (copy and paste)

- **App name:** Pinny (App Store Connect name: Pinny Family Map)
- **Bundle ID:** com.skyline.pinny
- **Apple ID of the app:** 6813281782
- **Category / type of app:** Personal safety — family location sharing with an SOS button

**What does the app do?**

> Pinny is a private family safety app. Family members share their location with each other only when they open the app, and each member has an SOS button. SOS requires a deliberate 1.5-second hold, then shares the sender's current location and alerts every other member of that family.

**Why do you need Critical Alerts?**

> The SOS alert is only useful if family members notice it immediately. Parents and carers often keep their phone muted or in a Focus mode (at work, asleep, in class). A standard or time-sensitive notification is silent in those cases, so an emergency message from a child or an elderly parent can go unseen for hours. We request Critical Alerts solely for the SOS notification so that it sounds even when the device is muted.

**Which notifications will be sent as critical?**

> Only one: "SOS from {name}", sent when a family member deliberately triggers SOS with a 1.5-second hold-to-confirm gesture. It is never sent automatically, never used for marketing, reminders, check-ins, chat messages or any other content. Check-in notifications and everything else remain standard notifications.

**How often?**

> Rarely. It is user-initiated, emergency-only, and limited to the sender's own family group (typically 2–6 people who joined with a private invite code). A user can disable Critical Alerts for Pinny at any time in iOS Settings.

**How do users consent?**

> The app asks for notification permission with a pre-permission screen that explains SOS alerts. Critical Alerts use the separate system permission prompt, shown once, with the same explanation. The app works without it.

## 3. After Apple approves (Claude does these)

1. `project.yml` entitlements: add `com.apple.developer.usernotifications.critical-alerts: true`.
2. Apple Developer → Identifiers → com.skyline.pinny: the Critical Alerts capability appears once granted; enable it (or re-run `asc-setup`).
3. Client: add `.criticalAlert` to `requestAuthorization(options:)` in `FirebaseNotificationService`.
4. Server: set the Functions env `CRITICAL_ALERTS_ENABLED=true` (the SOS payload then uses `sound: { critical: 1, name: "sos.wav", volume: 1.0 }`).
5. New build → TestFlight; test with the mute switch on.

## 4. Status

- 2026-09-18: request submitted by Claude on the owner's instruction. Apple Request ID **HBRVCF33Z9**. Apple replies by email to the Account Holder.
