# FamilyMap — Backend Setup (Firebase)

Backend for the FamilyMap iOS app: Firebase Authentication, Cloud Firestore,
Cloud Messaging (APNs via FCM) and Cloud Functions (Node 22, TypeScript, 2nd gen).

Everything backend lives in `firebase/`. No secrets are committed — every ID
below is a placeholder in CAPS.

```
firebase/
  firebase.json            # rules / indexes / functions / hosting wiring
  .firebaserc              # "default": "YOUR_FIREBASE_PROJECT_ID"
  firestore.rules          # security rules (deny by default)
  firestore.indexes.json   # composite indexes (none needed today)
  functions/               # Cloud Functions (TypeScript)
  hosting/                 # public privacy + support pages (Firebase Hosting, §12)
  tests/                   # security-rules tests (emulator, demo project)
```

---

## 1. Firebase project

Use a **separate project** for this app (do not reuse the existing NOGADA
Firebase project; create a new one): it keeps family location data, billing
and rules isolated from NOGADA.

1. [Firebase console](https://console.firebase.google.com) → **Add project** → name it `pinny-YOURSUFFIX`. The project ID is public: it's part of the privacy / support page URLs (`https://PROJECT_ID.web.app`, §12).
2. Google Analytics: off (not needed).
3. Upgrade to the **Blaze** plan (required for 2nd-gen Cloud Functions and outbound network / FCM). Set a budget alert (e.g. AUD 10).
4. **Project settings → General → Your apps → Add app → iOS**
   - Apple bundle ID: `com.skyline.pinny`
   - App nickname: `Pinny iOS`
   - App Store ID: leave blank for now
5. Download `GoogleService-Info.plist` and place it at
   `FamilyMap/Resources/GoogleService-Info.plist`.
   It is already gitignored — never commit it.
6. Put the project ID into `firebase/.firebaserc` (replace `YOUR_FIREBASE_PROJECT_ID`), or run `firebase use --add`.

## 2. Authentication

Console → **Build → Authentication → Sign-in method**.

### Email/Password
Enable **Email/Password** (leave "Email link" off).

Then **Authentication → Settings → User actions → turn OFF Email Enumeration
Protection**. New Firebase projects enable it by default, which makes an
unknown email return `invalid-credential` instead of `user-not-found`, so the
app cannot show "No account with that email. Create one?".
Trade-off: it becomes slightly easier to probe whether an email is registered;
acceptable for a family app.

### Sign in with Apple
Apple side ([developer.apple.com](https://developer.apple.com/account)):

1. **Identifiers → App IDs → `com.skyline.pinny`** → enable capability *Sign in with Apple*.
2. **Identifiers → Services IDs → +** → identifier `com.skyline.pinny.signin`, enable *Sign in with Apple*, **Configure**:
   - Primary App ID: `com.skyline.pinny`
   - Domains: `YOUR_FIREBASE_PROJECT_ID.firebaseapp.com`
   - Return URLs: `https://YOUR_FIREBASE_PROJECT_ID.firebaseapp.com/__/auth/handler`
3. **Keys → +** → name `FamilyMap SIWA`, enable *Sign in with Apple*, configure with the primary App ID. Download the `.p8` once (cannot be re-downloaded). Note the **Key ID**.
4. Note your **Team ID** (Membership page).

Firebase side → enable **Apple** and fill in:

| Console field | Value |
|---|---|
| Services ID | `com.skyline.pinny.signin` |
| Apple Team ID | `YOUR_APPLE_TEAM_ID` |
| Key ID | `YOUR_SIWA_KEY_ID` |
| Private key | paste contents of the SIWA `.p8` |

Native iOS sign-in only needs the App ID capability; the Services ID / key are
required by Firebase for token validation and for the "hide my email" relay.

Account deletion calls revokeToken — the Sign in with Apple key MUST be configured in Firebase before testing delete.

## 3. Push notifications (APNs → FCM)

Apple Developer → **Keys → +** → name `FamilyMap APNs`, enable *Apple Push
Notifications service (APNs)*. Download the `.p8` (one APNs key can serve all
your apps; reuse it if you already have one). Note the **Key ID**.

Firebase → **Project settings → Cloud Messaging → Apple app configuration →
APNs Authentication Key → Upload**:

| Field | Value |
|---|---|
| APNs auth key | the APNs `.p8` |
| Key ID | `YOUR_APNS_KEY_ID` |
| Team ID | `YOUR_APPLE_TEAM_ID` |

Xcode → target **FamilyMap → Signing & Capabilities → +**:

- **Push Notifications**
- **Sign in with Apple**
- **Time Sensitive Notifications** (SOS pushes; see §5 "APNs and Time Sensitive")
- **Background Modes → Remote notifications**

Client contract: after `UNUserNotificationCenter` permission is granted, pass
the APNs device token to Firebase Messaging, then write the FCM token to
`pushTokens/{uid}` (owner-only; not on `users/{uid}`, which family members
can read). Full token lifecycle (save, refresh, sign-out, server cleanup):
§7. Payload keys for tap routing: §5 "Push payloads".

## 4. Cloud Firestore

Console → **Build → Firestore Database → Create database**:

- Mode: **Production** (rules deny everything until you deploy `firestore.rules`).
- Location: **`australia-southeast1` (Sydney)** — closest to the owner; the
  Functions region is pinned to the same value in `functions/src/index.ts`
  (`REGION`). Location cannot be changed later.

Deploy rules and indexes:

```bash
cd firebase
firebase deploy --only firestore
```

## 5. Cloud Functions

```bash
cd firebase/functions
npm install
npm run build              # tsc -> lib/
cd ..
firebase deploy --only functions
firebase functions:log     # tail logs
```

- Runtime `nodejs22` (`firebase.json` + `engines` in `functions/package.json`), region `australia-southeast1`, `maxInstances: 10`.
  Google deprecates `nodejs22` on 2027-04-30 and decommissions it on 2027-10-31. Move to the next LTS before then.
- Firestore 2nd-gen triggers must run in the same region as the database; if
  you chose a different Firestore location, change `REGION` to match.
- `onUserDeleted` is a 1st-gen Auth trigger (2nd gen has no Auth delete event);
  it deploys alongside the 2nd-gen functions from the same codebase.
- Local test: `npm run serve` starts the Functions + Firestore emulators
  (needs Java 11+; use `--project demo-familymap` to avoid touching production).

| Function | Trigger | What it does |
|---|---|---|
| `onLocationUpdated` | `users/{uid}` updated | Push to the other family members with `notifyOnCheckIn == true` and a `pushTokens/{uid}` doc when the update is a fresh share: the user's first share ever, or `lastLocation.updatedAt` (server time) moved forward by 10 min or more. Name / settings updates, users without a family, repeat shares within 10 min and **SOS shares (`lastLocation.src == "sos"`)** send nothing; `src` `"open"`, `"manual"` or absent (legacy) take the normal path. Before sending it reads `families/{familyId}/places` ordered by `createdAt` (oldest first, like the app, so an exact distance tie picks the same place; skipped when nobody opted in) and applies the "inside a place" rule. Copy: title "`{name}` checked in"; body "At `{placeName}`." when inside a place, otherwise "Tap to see where they are.". Decision logic: `shouldNotifyCheckIn` in `functions/src/checkin.ts` and `placeFor` in `functions/src/places.ts`, both unit-tested by `npm test` in `functions/`. APNs priority 5, `sound: default`. Data payload `{type:"checkin", uid, familyId}`. |
| `onUserTokenWritten` | `pushTokens/{uid}` written (create / update / delete) | **One phone, one account.** When `token` changes to a new non-empty string, queries `pushTokens` where `token ==` that token and deletes every doc except `{uid}` (one batch). This closes the offline sign-out gap: the old account's stale token doc is deleted as soon as the next account on the phone saves the same token. Loop-safe: `tokenChanged` in `functions/src/token.ts` (unit-tested) fires only when the token changed to a non-empty value, so deletes — this function's own writes, sign-out, dead-token clean-up, account deletion — do nothing, and so does re-saving the same token. The query uses the automatic single-field index. |
| `onSOSMessage` | `chats/{familyId}/messages/{id}` created | `type == "sos"` only; normal chat messages return at once (**chat sends no pushes**, DESIGN-SPEC §13.5). Push to **every other member with a `pushTokens/{uid}` doc**, ignoring `notifyOnCheckIn`. Title "🚨 SOS from `{name}`" (`users/{senderId}.name`, falling back to `senderName`). Body "Tap to see where they are." when the SOS carried a location, else "Location unavailable." — "carried a location" = the sender's `lastLocation.src == "sos"` and its `updatedAt` is no more than 60 s before the message's `createdAt` (both server times; a location stamped at or after `createdAt` also counts). Decision logic: `sosBody` in `functions/src/sos.ts`, unit-tested. The message text and coordinates are never in the push. APNs priority 10, `sound: default`, `interruption-level: time-sensitive`. Data `{type:"sos", uid, familyId}`. |
| `onFamilyUpdated` | `families/{familyId}` updated | Housekeeping after a client-side leave. If `members` is empty → `purgeFamily`: deletes the family and its `inviteCodes/{code}` (transaction, re-checks `members` is still empty), then `recursiveDelete` on `families/{familyId}/places` and `chats/{familyId}` (also swept when the family doc is already gone, so a half-finished earlier run leaves nothing behind). Else if `createdBy` is no longer in `members` → sets `createdBy = members[0]`. Loop-safe: purge removes the doc (no further updates); promotion re-fires once and then finds nothing to do. |
| `onUserDeleted` | Firebase Auth user deleted | Removes uid from `families/{id}.members` (promoting `members[0]` if the creator left) and deletes `users/{uid}` and `pushTokens/{uid}` in one transaction; if the family is now empty, calls the same `purgeFamily` helper (idempotent with `onFamilyUpdated`). |

**SOS double push — resolved in Stage 3.6.** The SOS flow writes
`lastLocation` just before the SOS message. That write now carries
`src: "sos"`, and `shouldNotifyCheckIn` returns false for it, so the family
gets only the SOS push (no extra "checked in"). The Stage 4 open item is
closed; Stage 4 only has to send `src: "sos"` on that write.

**"Inside a place" rule** (contract §4; same rule on the viewer's device):
a place matches when the haversine distance from `lastLocation` to its centre
is ≤ `radius` **and** `acc` is absent (legacy) or ≤ that place's `radius` (a
fix less precise than the place never matches it); if several places match,
the nearest centre wins.

**Recipients and dead tokens.** Recipients are the family's `users` (query
`familyId ==`, minus the sender, filtered by `notifyOnCheckIn` for check-ins);
their tokens are read from `pushTokens/{uid}` in one `getAll`. Members
without a token doc are skipped. Every send is `sendEachForMulticast`. A
token FCM reports as `messaging/registration-token-not-registered` or
`messaging/invalid-registration-token` has its `pushTokens/{uid}` doc
deleted; other failures are only logged.

### Push payloads (iOS tap routing, DESIGN-SPEC §13.5)

Both pushes are an FCM `notification` (title + body) plus string-only `data`
keys, which arrive at the top level of the APNs `userInfo` (next to `aps`).

| Key | Check-in push | SOS push | Use |
|---|---|---|---|
| `type` | `"checkin"` | `"sos"` | Which push it is. Anything else (or missing): open the Map tab, nothing more. |
| `uid` | the member who shared | the SOS sender | Member to select, centre and expand in the drawer. |
| `familyId` | sender's family | sender's family | Route only if it equals my current `familyId` and `uid` is still in my members; otherwise open the Map tab and do nothing else. |

No other keys (the old SOS `messageId` is dropped: the SOS card is found in
Chat by its `type`). Chat messages send no push in this stage.

| | Check-in | SOS |
|---|---|---|
| `apns-priority` | `5` | `10` |
| `aps.sound` | `default` | `default` |
| `aps.interruption-level` | not set (active) | `time-sensitive` |
| Honours `notifyOnCheckIn` | yes (opt-in) | no — always sent |

In the foreground the app decides presentation in
`userNotificationCenter(_:willPresent:)`: SOS → `[.banner, .sound, .list]`,
check-in → `[.banner, .list]` (silent banner, §13.5).

### APNs and Time Sensitive

- `interruption-level: time-sensitive` breaks through Focus and is shown
  immediately only when the app has the
  `com.apple.developer.usernotifications.time-sensitive` entitlement (Xcode →
  **Time Sensitive Notifications**; `project.yml` already sets it) and the App
  ID has the matching capability (TESTFLIGHT A1). Without it iOS silently
  downgrades the SOS to a normal (active) alert — it still arrives.
- The user can still turn Time Sensitive off per app (iOS Settings → Pinny →
  Notifications). Server-side nothing else is needed: FCM sets
  `apns-push-type: alert` for notification messages.
- Pushes need the APNs key uploaded (§3); FCM picks the sandbox or production
  APNs endpoint from the token, so Debug builds (`aps-environment =
  development`) and TestFlight builds (production) both work with the same key.
- Critical alerts (sound through the mute switch) are **not** used; they need a
  separate Apple entitlement request.

## 6. Data model

```
families/{familyId}
  name: string                  1–40 UTF-16 units
  inviteCode: string            6 chars [A-Z0-9], unique
  members: [uid, ...]
  createdBy: uid
  createdAt: timestamp          == server time on create

families/{familyId}/places/{placeId}      Stage 3.6, max 10 per family (client-enforced)
  name: string                  1–30 UTF-16 units
  icon: string                  "home" | "school" | "work" | "pin"
  lat: number                   -90..90
  lng: number                   -180..180
  radius: int                   100..500 metres (whole number)
  createdBy: uid                == caller on create; immutable
  createdAt: timestamp          == server time on create; immutable

users/{uid}                     readable by the owner and the same family
  name: string                  1–40 UTF-16 units
  photoURL: string?
  familyId: string?             null = not in a family
  lastLocation: {
    lat: number                 -90..90
    lng: number                 -180..180
    updatedAt: timestamp        == server time when written
    acc: int?                   horizontal accuracy, whole metres, 0..100000
    battery: int?               0..100 (omitted when unknown, e.g. simulator)
    charging: bool?
    src: string?                "open" | "manual" | "sos" (Stage 3.6); absent on legacy writes
  }?                            no other keys; optional fields omitted, never null
  notifyOnCheckIn: boolean      default true
  updatedAt: timestamp
                                (no fcmToken — rejected since Stage 4; see pushTokens)

pushTokens/{uid}                Stage 4, owner-only (read and write); not even family
  token: string                 FCM registration token, 1–4096 chars
  updatedAt: timestamp          == server time when written

chats/{familyId}/messages/{messageId}
  senderId: uid
  senderName: string            1–40 UTF-16 units
  text: string                  1–1000 UTF-16 units
  type: "normal" | "sos"
  createdAt: timestamp          == server time on create

inviteCodes/{code} -> { familyId }   lookup table; joining never lists families
```

Indexes: messages are queried by `createdAt` only (single-field, automatic).
Users are queried by `familyId ==` (single-field). Places are read as a whole
subcollection (the server orders by `createdAt`, single-field). Push tokens
are queried by `token ==` (server only, single-field). No composite index
needed; `firestore.indexes.json` is intentionally empty.

**String lengths** are counted in UTF-16 code units, as the rules'
`size()` does (pinned by tests): an emoji counts 2 or more, so 15 × "🏠" is
a valid 30-unit place name and 29 letters + "🏠" (31) is rejected. Swift:
count `name.utf16.count`, not `name.count`.

## 7. Client write contracts

What the iOS client writes for each action. Rules reject anything else.

| Client action | Writes (all client-side, subject to rules) |
|---|---|
| Sign in (first time) | `users/{uid}` **create**: `{ name, photoURL?, notifyOnCheckIn: true, updatedAt: serverTimestamp }`. `familyId` absent/null. `name` 1–40 UTF-16 units. No `fcmToken` key (rejected, even as `null`; remove it from the Swift `AppUser` model). |
| Save push token | `pushTokens/{uid}` **set** (whole doc) `{ token, updatedAt: serverTimestamp }` — exactly these two keys; `token` the FCM token, a non-empty string ≤ 4096 chars. **When:** on every launch once notifications are allowed, and whenever `messaging(_:didReceiveRegistrationToken:)` delivers a token — but only if the **server copy differs** (`getDocument` on `pushTokens/{uid}`: missing, or `token` ≠ the current one). Comparing with the server, not a local cache, restores a token the server removed. Only the owner can read or write it; family members can't. |
| Toggle check-in notifications | `users/{uid}` update `{ notifyOnCheckIn: Bool, updatedAt: serverTimestamp }` (`notifyOnCheckIn` a Bool; `null` or a string is rejected). Written as a **write-only transaction**, like location: it fails offline instead of sitting in the offline queue, so a failed or timed-out save is never replayed. Saves at once; on failure the toggle flips back to the user doc's value (DESIGN-SPEC §13.2). Affects check-in pushes only — SOS ignores it. |
| Sign out | **Before** `Auth.auth().signOut()` (the delete needs auth): `pushTokens/{uid}` **delete**, then `Messaging.messaging().deleteToken()` so the next account on this phone gets a new token. Best effort: if offline, sign out anyway (DESIGN-SPEC §9.6 has no error state). **Offline gap resolved server-side:** when the next account signs in on this phone and saves the same token, `onUserTokenWritten` deletes the old account's token doc, so the old family's pushes stop reaching the phone. Until someone signs in, the signed-out phone can still get them; DESIGN-SPEC §13.5 routes such a tap to the Map tab only. |
| Token removed by the server | Not a client action. `pushTokens/{uid}` is deleted by Functions when FCM reports the token invalid (§5 "Recipients and dead tokens"), when another account saves the same token (`onUserTokenWritten`), and on account deletion (`onUserDeleted`). The next launch finds the server copy missing and saves the token again. |
| Create family | **One WriteBatch**: `families/{newId}` create `{ name, inviteCode, members:[uid], createdBy: uid, createdAt: serverTimestamp }` + `inviteCodes/{code}` create `{ familyId }` + `users/{uid}` update `familyId`. Generate `code` client-side (`[A-Z0-9]{6}`); if the batch fails with permission-denied the code already exists — regenerate and retry. |
| Join family | Read `inviteCodes/{code}` (get). Then **one WriteBatch**: `families/{familyId}` update `members: arrayUnion(uid)` + `users/{uid}` update `familyId`. |
| Leave family | **One WriteBatch**: `families/{familyId}` update `members: arrayRemove(uid)` + `users/{uid}` update `familyId: null` (`FieldValue.delete()` is accepted too). The rules **reject** the `arrayRemove` unless `users/{uid}.familyId` is cleared in the same batch, so a departed member can never keep reading the family's pins. Empty family is purged server-side; creator promoted if creator leaves (`onFamilyUpdated`). The last member leaving (`members` → `[]`) is what triggers the purge. |
| Delete family | **Not a client action.** Clients never delete `families/{id}` or `inviteCodes/{code}` (rules: `delete: false`); only `purgeFamily` (Admin SDK) does, after the last member leaves. |
| Rename family | `families/{familyId}` update `name` (creator only). Family `name` is 1–40 UTF-16 units, on create and rename. |
| App opened / foregrounded, manual refresh / Check in | `users/{uid}` update `lastLocation: { lat, lng, updatedAt: serverTimestamp, acc?, battery?, charging?, src }` + `updatedAt: serverTimestamp`. From Stage 3.6 every location write sets `src`: `"open"` for the automatic share on app open / foreground, `"manual"` for Refresh / Check in (`"sos"`: see SOS row); any other value, or a non-string, is rejected. Replace the whole `lastLocation` map in one write, as a write-only **transaction** (fails offline instead of queueing a stale position that the server would stamp as fresh on reconnect). `lastLocation.updatedAt` **must** be `serverTimestamp()`; a device `Date` is rejected, and so is any change to `lastLocation` (e.g. battery alone) that is not re-stamped. `acc` and `battery` must be integers (e.g. `Int(horizontalAccuracy.rounded())`, `Int((level * 100).rounded())`), not Doubles; omit unknown fields rather than writing null. Other updates (name, settings) may leave an old `lastLocation` untouched. |
| Read family pins | `users` query `whereField("familyId", isEqualTo: myFamilyId)` (the equality filter is what makes the read rule provable). |
| Read places | `families/{familyId}/places` listen to the whole subcollection (members only). |
| Add place | `families/{familyId}/places/{auto}` create `{ name, icon, lat, lng, radius, createdBy: uid, createdAt: serverTimestamp }` — all seven keys, nothing else. `name` 1–30 UTF-16 units (an emoji counts 2+; see §6 "String lengths"); `icon` one of `"home" \| "school" \| "work" \| "pin"`; `radius` an **Int** 100–500 (`Int`, not `Double` — `150.5` is rejected). Hide "Add place" at 10 places; rules cannot count documents, so the cap is the client's job. |
| Edit place | `families/{familyId}/places/{placeId}` update any of `name`, `icon`, `lat`, `lng`, `radius` (same validation as create). `createdBy` / `createdAt` can't change; any member may edit any place. |
| Delete place | `families/{familyId}/places/{placeId}` delete (any member). |
| Send chat message | `chats/{familyId}/messages/{id}` create `{ senderId: uid, senderName, text, type: "normal", createdAt: serverTimestamp }` — exactly these five keys. `senderName` a string 1–40 UTF-16 units; `text` 1–1000 UTF-16 units (trim first; empty is rejected; the §13.4 counter and the 1000 cap must count `text.utf16.count`); `createdAt` **must** be `serverTimestamp()`. Written as a **write-only transaction**, like location: it fails offline instead of sitting in the offline queue, and a failed send is never replayed by the SDK; only the user's retry sends it again. Make the ID client-side before the first write and reuse it on retry: messages are create-only, so a retry of a write that already landed is rejected (permission-denied) — then `getDocument` it; if it exists, mark sent (DESIGN-SPEC §13.4). No push is sent for chat messages. |
| SOS | Make the message ID first. **1.** If there is a fix: `users/{uid}` update `lastLocation: { lat, lng, updatedAt: serverTimestamp, acc?, battery?, charging?, src: "sos" }` + `updatedAt: serverTimestamp` (same transaction write as a normal share); wait for it to commit. The fix may be the device's cached one (DESIGN-SPEC §13.3: no fresh fix within 3 s → a cached fix ≤ 2 min old), so **an SOS location can be up to 2 min older than its timestamp**; `updatedAt` is when it was shared, not when it was measured. Location off / no fix → skip this step. **2.** `chats/{familyId}/messages/{id}` create `{ senderId: uid, senderName, text: "SOS", type: "sos", createdAt: serverTimestamp }` — `text` is exactly `"SOS"` (fixed, never shown; clients draw the SOS card from `type`). Also a **write-only transaction** (never queued offline; a failed send is not replayed). Try again reuses the ID; permission-denied + document exists = already sent (one SOS, never two). `onSOSMessage` pushes to everyone else; the body says "Tap to see where they are." only if step 1 landed ≤ 60 s before the message, so a skipped step 1 (or an old SOS location) gives "Location unavailable.". The `src: "sos"` write sends no check-in push. |
| Delete account | `Auth.auth().currentUser?.delete()` (re-authenticate first if Firebase asks). `onUserDeleted` cleans Firestore, `pushTokens/{uid}` included — no client token delete needed. Client should also clear local state. |

Messages cannot be edited or deleted by clients (rules: `update, delete: false`).
Families and invite codes cannot be deleted by clients either — server purge only.

## 8. Security notes

- **No secrets in the repo.** `GoogleService-Info.plist`, `.p8` keys and
  service-account JSON are never committed. Functions use the default
  service account — no keys in code.
- **Rules deny by default.** Every allowed path is explicit; document shapes
  are validated (`hasOnly` on keys, type + range checks) so a client cannot
  add stray fields.
- **Location visibility = family only.** `users/{uid}` is readable only by the
  owner and by users whose own `familyId` matches. Family docs are readable by
  members only. Invite codes can be fetched one at a time by a signed-in user
  but never listed.
- **Places = family only.** `families/{familyId}/places` is readable and
  writable only by users currently in that family's `members` (checked
  against the family doc, so a leaver loses access in the same commit).
  Create requires all fields with `hasOnly` / `hasAll`, `createdBy == uid`
  and `createdAt == request.time`; update may touch only `name`, `icon`,
  `lat`, `lng`, `radius`, re-validated.
- **Push tokens = owner only.** `pushTokens/{uid}` can be read, created,
  replaced or deleted only by `{uid}` (`hasOnly` / `hasAll` on
  `token` + `updatedAt`, `updatedAt == request.time`); Functions read it
  with the Admin SDK. `users/{uid}` rejects an `fcmToken` key. This closes
  the Stage 4 "silence someone's alerts" risk: when the token sat on
  `users/{uid}`, family members could read it, and copying it into their
  own doc would have made `onUserTokenWritten` strip it from the victim, so
  they'd get no SOS pushes. Nobody but the owner can now learn a token.
- **Data minimisation.** Only the *last* location is stored; each check-in
  overwrites it. No history, no background tracking — location is captured
  only in the foreground (see §9).
- **Membership changes are self-service only.** A user can add or remove
  *only their own uid* from `members` (size-diff-of-1 check). Nobody can add
  someone else. Leaving must also clear `users/{uid}.familyId` in the same
  batch (`getAfter` check), so `familyId` set ⇒ currently a member.
- **Known trade-off.** Joining requires the `familyId` (obtained from the
  invite code). Rules cannot verify the caller actually read the code, so
  anyone who learns a `familyId` could join. Family IDs are 20-char random
  Firestore IDs exposed only to members; acceptable for a family-only app.
  A callable function could be added later if this needs hardening.
- **Account deletion** (Apple 5.1.1(v)) is fully server-side via
  `onUserDeleted`, so a half-finished client cannot leave orphaned data.

## 9. Location data (privacy)

Source for the App Store privacy label and the in-app privacy copy. Update
this section if anything below changes.

| | |
|---|---|
| **What is stored** | `users/{uid}.lastLocation = { lat, lng, updatedAt, acc?, battery?, charging?, src? }`: device coordinates, **location accuracy** (metres), **battery level and charging state**, what triggered the share (`src`: open / manual / sos), plus the **server** time of the write (rules require `serverTimestamp()`). All captured together, only at share time; nothing is sampled in between, so battery can be as old as the location. One value per user; each share **overwrites** it. No history and no other fields (rules reject extra keys such as speed). |
| **Saved places** | Saved places are visible to your family only. `families/{familyId}/places` holds a name, icon, centre and radius typed in by a member (up to 10). Places only **label** a location that was already shared; nothing is monitored and "inside a place" is never stored (computed on the viewer's device, and by `onLocationUpdated` for the push body). Place search text is sent to Apple to find addresses (`MKLocalSearch` in the place editor); FamilyMap stores only the saved result. Places are **shared family data**, not personal data: a place stays with the family when its creator leaves or deletes their account (its `createdBy` uid remains), any member can delete it, and all places are deleted with the family when the last member leaves (`purgeFamily`). |
| **Push token** | `pushTokens/{uid} = { token, updatedAt }`: this phone's FCM registration token (the "Device ID" row in `PrivacyInfo.xcprivacy`). Visible **only to the owner and the server** (Cloud Functions, to send pushes) — not to family. One per user; deleted on sign-out, when FCM reports it invalid, when another account on the same phone saves it, and on account deletion. |
| **When it is written** | Foreground only: app opened / foregrounded, Refresh / Check in, and (stage 4) just before an SOS message. No background tracking. `updatedAt` is when the location was shared. For an SOS the phone may use its cached fix when no fresh one arrives within 3 s, so an SOS location can be up to 2 min older than its timestamp (cached fix). |
| **Who can read it** | Location, accuracy and battery alike: the user and members of the **same family** only, enforced by `firestore.rules` (`users/{uid}` read requires the reader's `familyId` to match). Covered by the "location" suite in `firebase/tests` (places: the "places" suite). Cloud Functions use it only to decide whether the SOS push says "Tap to see where they are." (`src` and `updatedAt`, never the coordinates) and to pick the saved place named in the check-in push. |
| **Leaving a family** | The leave batch clears `users/{uid}.familyId`, so from that commit the leaver can't read the family's locations and the family can't read the leaver's. The leaver's own `lastLocation` stays on their doc, visible only to them, until it is overwritten or the account is deleted. |
| **Deletion** | Deleting the account (Settings → Delete account → Firebase Auth delete) fires `onUserDeleted`, which deletes `users/{uid}`, `lastLocation` (with battery and accuracy) included, and `pushTokens/{uid}`. This matches the Settings privacy line "Delete your account at any time to remove your account and location data." Saved places are not part of that: they are shared family data and stay with the family (see Saved places). If the user was the last member, the family is purged, places included. |
| **Street addresses** | Never stored. The "Near 12 George St" line is geocoded on the viewer's device with Apple's geocoder (`CLGeocoder`) and held in memory only. Apple receives the coordinate for that lookup; say so in the privacy policy. |
| **Copies elsewhere** | None stored. Pushes carry no coordinates: the check-in push body may carry a saved place name ("At Home.") through FCM/APNs, but it isn't saved, and push data holds only `type`, `uid` and `familyId`; chat messages store only the typed text. Functions log uids, never coordinates. **On-device cache:** the Firestore SDK keeps each member's last-seen family locations on the phone's disk (offline persistence), until overwritten by a newer snapshot or the app is deleted. Location writes don't sit in the offline write queue: the client writes them in a transaction, which fails offline and is never replayed. Open (Stage 6): call `clearPersistence()` on sign-out and account deletion so a shared or handed-down phone keeps no family locations. Firestore point-in-time recovery and backups are off (the default). Turning either on keeps past values for its retention period, so update this section if you do. |

App Store privacy label (location and battery rows):

| Data type | Linked to user | Used for tracking | Purpose |
|---|---|---|---|
| Precise Location (incl. accuracy) | Yes | No | App Functionality |
| Other Data (battery level, charging state) | Yes | No | App Functionality |

Battery has no Apple privacy category of its own, so it goes under "Other
Data". Linked because both are stored on the user's own doc. Not tracking
because neither is shared with third parties or combined with other
companies' data for advertising. This table covers location and battery
only; other collected data (name, email, user ID) needs its own rows.

## 10. Testing

`firebase/tests/` runs the rules against the Firestore emulator with
`@firebase/rules-unit-testing` and `node:test` (needs Java 11+, no real
project — uses `--project demo-familymap`). Every case in §7 has a
should-pass test and the abuse variants have should-fail tests; the database
is cleared before each test.

```bash
cd firebase/tests
npm install
npm test        # = firebase emulators:exec --only firestore --project demo-familymap "node --test rules.test.mjs"
```

Run it after any change to `firestore.rules`.

Functions unit tests (pure check-in, "inside a place", SOS-body and token-change logic, no emulator):

```bash
cd firebase/functions
npm test        # = npm run build && node --test test/checkin.test.mjs test/places.test.mjs test/sos.test.mjs test/token.test.mjs
```

Test files are listed explicitly (Node 24 lesson: don't rely on
`node --test` discovering them). Add new files to the `test` script.

Windows note: `emulators:exec` sometimes leaves the Java emulator running
after the script exits. If the next run says "Port 8080 is not open", stop the
stray process: `Get-NetTCPConnection -LocalPort 8080 | % { Stop-Process -Id $_.OwningProcess -Force }`.

## 11. Command reference

```bash
# one-time
npm install -g firebase-tools
firebase login
cd firebase
firebase use --add                       # pick YOUR_FIREBASE_PROJECT_ID, alias "default"

# Firestore rules + indexes
firebase deploy --only firestore

# Cloud Functions
cd functions && npm install && npm run build && cd ..
firebase deploy --only functions
firebase functions:log

# Privacy + support pages (§12)
firebase deploy --only hosting

# everything
firebase deploy

# local emulators (rules + functions), no real project needed
firebase emulators:start --only firestore,functions --project demo-familymap

# rules tests
cd tests && npm install && npm test
```

## 12. Privacy and support pages (Firebase Hosting)

App Store Connect needs a public **privacy policy URL** (required for external
TestFlight testing and for the App Store) and a **support URL**. They're
static pages on Firebase Hosting in the same project, so there's no extra
service to sign up for.

| File | URL after deploy |
|---|---|
| `firebase/hosting/privacy.html` | `https://PROJECT_ID.web.app/privacy` |
| `firebase/hosting/support.html` | `https://PROJECT_ID.web.app/support` |

`firebase.json` → `hosting.public = "hosting"`, with `cleanUrls` so the URLs drop `.html`.

Before the first deploy, replace every `SUPPORT_EMAIL` in both pages with the
support address the owner chooses. Then run `firebase deploy --only hosting`
from `firebase/`.

The privacy page restates §9 in plain English. If §9 changes (new fields, new
copies, retention), update `privacy.html` and its "Last updated" date in the
same change.
