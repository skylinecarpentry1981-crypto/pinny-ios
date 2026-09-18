# Pinny

Pinny is family-only iOS location sharing (the Xcode project, target and folders are still named `FamilyMap` internally). Your location is captured **only when you open the app** (no background tracking), uploaded once, and shown to your family as a pin with a "last updated" time. Also: family create/join by invite code, one group chat, push notifications, and an SOS button.

- iOS 16+, SwiftUI, MapKit, CoreLocation
- Firebase (Auth, Firestore, Messaging) via Swift Package Manager
- Project file is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`

## Mac setup

```sh
brew install xcodegen
cd family-map-ios
xcodegen generate
```

1. Download `GoogleService-Info.plist` from the Firebase console and drop it into `FamilyMap/Resources/` (it is gitignored; see `GoogleService-Info.plist.example`).
2. Set `DEVELOPMENT_TEAM` in `project.yml` (or pick your team in Xcode > Signing) and re-run `xcodegen generate`.
3. Open `FamilyMap.xcodeproj`, let SPM resolve Firebase, select an iPhone, run.

Push notifications and Sign in with Apple need the matching capabilities enabled on the App ID in the Apple Developer portal.

## Docs

- [Design spec](docs/DESIGN-SPEC.md) - screens, exact copy, colour tokens
- [Backend setup](docs/BACKEND-SETUP.md) - Firebase project, Firestore rules, Cloud Functions
- [Build plan](docs/BUILD-PLAN.md) - stage-by-stage scope

## Firebase deploy

Rules and functions live in `firebase/`. Follow [docs/BACKEND-SETUP.md](docs/BACKEND-SETUP.md) for the `firebase deploy` steps.

## Stage status (7 stages)

| Stage | Scope | Status |
|-------|-------|--------|
| 1 | Scaffold: navigation, Firebase config, services/protocols, design system | Done |
| 2 | Auth (Sign in with Apple / email) + family create/join/leave, name edit, account deletion | Done |
| 3 | Location capture on open + Firestore upload + map pins | Done |
| 3.5 | Map home — drawer, battery, on-device place names | Done |
| 3.6 | Family Places (app-open only) | In review |
| 4 | Push notifications (FCM token, check-in alerts) + SOS | In review |
| 5 | Group chat | In review |
| 6 | Final review + polish (account deletion shipped in stage 2) | TODO |
| 7 | Family Pass in-app purchase (StoreKit 2, server-verified) + worldwide App Store release | In review |

Search the code for `TODO(stage N)` to find every stub.
