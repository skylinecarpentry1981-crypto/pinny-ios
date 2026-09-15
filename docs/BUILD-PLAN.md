# FamilyMap — Build Plan

Family-only iOS location-sharing app. Location is captured **only when the app is opened** (no background tracking). SwiftUI · iOS 16+ · Firebase (Auth, Firestore, Messaging, Functions).

Team (every stage): Frontend Dev (SwiftUI) · Backend Dev (Firebase) · UI/UX Designer · Overseer (QA gate). The orchestrator marks a stage done only after the Overseer returns PASS.

Related docs: [DESIGN-SPEC.md](DESIGN-SPEC.md) · [BACKEND-SETUP.md](BACKEND-SETUP.md) · [OVERSEER-REVIEW.md](OVERSEER-REVIEW.md)

---

## Stage 1 — Scaffolding
**Goal:** runnable shell on a Mac — XcodeGen project, Firebase configured, full navigation with stubs.

- Designer
  - [x] DESIGN-SPEC.md: principles, nav map, all screens with L/E/X states, components, tokens, copy, a11y, relative-time rules
- Frontend
  - [x] `project.yml` (iOS 16, Firebase 11 SPM, Info.plist keys, entitlements)
  - [x] App entry, AppDelegate (Firebase configure, APNs → FCM token), RootView auth gate
  - [x] AppState + service protocols (Auth live; Family/Chat/Notification stubs; Location wrapper)
  - [x] Models: AppUser, LocationPoint, Family, ChatMessage
  - [x] Design system tokens + components
  - [x] Shell views: Welcome, Onboarding, MainTabView (Map / Chat / Family), Settings, SOS sheet
- Backend
  - [x] `firebase.json`, `.firebaserc` (placeholder project id)
  - [x] `firestore.rules` deny-by-default with field validation
  - [x] Functions: `onLocationUpdated`, `onSOSMessage`, `onUserDeleted`
  - [x] BACKEND-SETUP.md (console steps, APNs, SIWA, deploy commands, write contracts)
- Overseer
  - [x] Scaffold gate + compile-risk read + rules review (PASS after 1 return round) → see OVERSEER-REVIEW.md
- Owner (on Mac)
  - [ ] `brew install xcodegen && xcodegen generate`, add real `GoogleService-Info.plist`, set `DEVELOPMENT_TEAM`, build once

## Stage 2 — Auth + Family group (done)
- [x] Frontend: Sign in with Apple + email/password flows; user doc bootstrap; create / join family by code; Family tab live; Settings name edit; Delete account (Auth delete + re-auth)
- [x] Backend: verify rules for create/join batches against emulator; `onUserDeleted` cleanup tested
- [x] Designer: review onboarding copy + error states
- [x] Overseer: auth gate, rules deny tests, delete-account flow

## Stage 3 — Location + Map (done)
- [x] Frontend: `LocationSync` shares one fix on app open / Refresh (2 min throttle), write-only transaction (never queued offline), offline pre-check; pins with relative time + 24 h staleness; permission-denied banner; Family tab → Map focus
- [x] Backend: `lastLocation.updatedAt == request.time` rule; `shouldNotifyCheckIn` extracted + unit-tested; privacy section in BACKEND-SETUP §9
- [x] Designer: DESIGN-SPEC §10
- [x] Overseer: no background location APIs; permission copy; stale rendering (PASS after 2 return rounds)

## Stage 3.5 — Life360-style map home (done, owner-approved)
- [x] Frontend: draggable member drawer (3 snaps), row actions (Open in Maps / Message / Check in), SOS floating above drawer, on-device place names (`PlaceNameResolver`, never stored), battery + accuracy captured at share
- [x] Backend: optional `acc` / `battery` / `charging` in `validLocation`; 85 rules tests; privacy label rows
- [x] Designer: DESIGN-SPEC §11 + mockup
- [x] Overseer: PASS (review §"Stage 3/3.5 final")
- Carry-forward nits: pin re-tap deselects, drawer lift before the no-location guard, `geocodeFoundNoResult` resolved (all fixed in Stage 3.6); Legal link position in full snap (verify on device)

## Stage 3.6 — Family Places, app-open only (done)
Contract: [STAGE-3.6-CONTRACT.md](STAGE-3.6-CONTRACT.md). Places only label a location that was already shared; nothing is monitored, and there's no background location.
- [x] Frontend: Family tab Places section, place editor (search, Use my location, radius 100–500 m), place annotations on the map, "At {place}" drawer line, `src` on every location write
- [x] Backend: `families/{id}/places` rules and tests; place-aware check-in push (`placeFor`, unit-tested); `src: "sos"` sends no check-in push; `purgeFamily` also deletes places
- [x] Designer: DESIGN-SPEC §12
- [x] Overseer: first review returned; all return items fixed (confirmed in the Stage 4 + 5 review, OVERSEER-REVIEW.md)

## Stage 4 — Notifications + SOS (done)
- [x] Frontend: priming sheet (after the location prompt), push token saved to owner-only `pushTokens/{uid}`, check-in toggle, SOS hold-to-confirm 1.5 s → location (`src: "sos"`, takes over any in-flight fix, cached fix ≤ 2 min) → SOS message; push tap routing; Pinny rebrand
- [x] Backend: `onSOSMessage` copy per §13, `sosBody` unit-tested; `pushTokens` rules + `onUserTokenWritten` dedupe; Functions on Node 22
- [x] Designer: DESIGN-SPEC §13, Pinny tokens (accent, OnAccent, SOSRed, SOSRedText)
- [x] Overseer: first review returned (failed SOS could replay later); fixed with write-only transactions; re-review PASS

## Stage 5 — Chat (done)
- [x] Frontend: newest 100 + Load earlier, grouping, day separators, Sending / Failed / Retry, SOS card with Show on map, offline banner, mascot empty state
- [x] Backend: message rules (UTF-16 limits, append-only), no chat pushes
- [x] Designer: DESIGN-SPEC §13.4–§13.6
- [x] Overseer: PASS (Stage 4 + 5 re-review)

## Stage 6 — Final Overseer review (PASS)
- [x] Permissions, error handling, empty states, account flows, release settings, secrets scan of the GitHub repo
- Open before the family relies on SOS: Blaze + Functions deploy + APNs key (owner console steps in TESTFLIGHT.md)
- Before the App Store: Welcome "Privacy" link to the hosted policy, drop "Terms" (Overseer Stage 6 #2)
- Device checks: see the carry-forward table at the end of OVERSEER-REVIEW.md
