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
  functions/certs/         # Apple's public root CAs for offline purchase verification (§5.1)
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
  (`REGION`). Location cannot be changed later. The app is sold worldwide
  (Stage 7); every user's data is stored here, in Sydney, and the privacy
  page says so (§12).

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
| `onSOSMessage` | `chats/{familyId}/messages/{id}` created | `type == "sos"` only; normal chat messages return at once (**chat sends no pushes**, DESIGN-SPEC §13.5). Push to **every other member with a `pushTokens/{uid}` doc**, ignoring `notifyOnCheckIn`. Title "🚨 SOS from `{name}`" (`users/{senderId}.name`, falling back to `senderName`). Body "Tap to see where they are." when the SOS carried a location, else "Location unavailable." — "carried a location" = the sender's `lastLocation.src == "sos"` and its `updatedAt` is no more than 60 s before the message's `createdAt` (both server times; a location stamped at or after `createdAt` also counts). Decision logic: `sosBody` in `functions/src/sos.ts`, unit-tested. The message text and coordinates are never in the push. APNs priority 10, `sound: default`, `interruption-level: time-sensitive`. Data `{type:"sos", uid, familyId, messageId}`, header `apns-collapse-id` = the message ID (Stage 9). After the first push, if anyone was pushed to, it enqueues `sosReminder` attempt 1 for 30 s later; an enqueue failure is only logged (`could not enqueue sos reminder`), never fails the push. |
| `sosReminder` | **Task queue** (v2 `onTaskDispatched`, Cloud Tasks queue `sosReminder` in `australia-southeast1`; `retryConfig.maxAttempts: 1`, `rateLimits` 10 concurrent / 5 per second), payload `{ familyId, messageId, senderUid, attempt }` | Stage 9 (§5.2): **the SOS keeps alerting until acknowledged.** Attempts 1…9, 30 s apart (about 5 min). Each run: stop if the message is gone (or not an SOS); recipients = current family members with a `pushTokens/{uid}` doc, minus the sender, minus everyone with an ack doc `chats/{familyId}/messages/{messageId}/acks/{uid}`; stop when none remain; otherwise send the **same** SOS push (same title / body rule / data / siren / `apns-collapse-id`, so the new banner replaces the old one) and enqueue the next attempt until 9. A failed send is logged and the chain continues. Decision logic: `remainingRecipients`, `shouldContinue` and `validTask` in `functions/src/sosReminder.ts`, unit-tested. Not callable by clients: Cloud Run only admits the queue's OIDC-signed requests. |
| `onFamilyUpdated` | `families/{familyId}` updated | Housekeeping after a client-side leave. If `members` is empty → `purgeFamily`: deletes the family and its `inviteCodes/{code}` (transaction, re-checks `members` is still empty), then `recursiveDelete` on `families/{familyId}/places` and `chats/{familyId}` (also swept when the family doc is already gone, so a half-finished earlier run leaves nothing behind). Else if `createdBy` is no longer in `members` → sets `createdBy = members[0]`. Loop-safe: purge removes the doc (no further updates); promotion re-fires once and then finds nothing to do. |
| `onUserDeleted` | Firebase Auth user deleted | Removes uid from `families/{id}.members` (promoting `members[0]` if the creator left) and deletes `users/{uid}` and `pushTokens/{uid}` in one transaction; if the family is now empty, calls the same `purgeFamily` helper (idempotent with `onFamilyUpdated`). Then deletes every `passes/*` doc with `uid ==` the deleted uid (Stage 7; query on the automatic single-field index, one batch), releasing the Apple purchase for a re-created account. Finally deletes the profile photo `avatars/{uid}.jpg` from the default Storage bucket (Stage 8, `ignoreNotFound`; a Storage error is logged as a warning and does not fail the Firestore clean-up, which is already committed). |
| `redeemFamilyPass` | **Callable** (v2 `onCall`, region `australia-southeast1`, App Check not enforced), input `{ jws: string }` | Stage 7 (§5.1). Requires auth. Verifies the StoreKit 2 `jwsRepresentation` offline with Apple's `SignedDataVerifier` (bundle id `com.skyline.pinny`, environment Sandbox or Production taken from the payload and enforced against the signature, no online checks), then requires `productId == "com.skyline.pinny.family.pass"`, `type == "Non-Consumable"` and no `revocationDate` (`isValidPassTransaction` in `functions/src/pass.ts`, unit-tested). In one transaction: if `passes/{transactionId}` exists for **another** uid → error; else creates it (`{ uid, productId, redeemedAt }`, kept as-is on restore) and sets `users/{uid}.pass = { transactionId, productId, verifiedAt: serverTimestamp }` (merge). Returns `{ ok: true }`. Errors: `unauthenticated` "Sign in to redeem a purchase."; `invalid-argument` "Missing purchase data." / "Purchase data isn't readable." / "Couldn't verify the purchase."; `failed-precondition` "This purchase isn't an active Family Pass." (wrong product / type, refunded); `already-exists` "This purchase is already used by another account.". Logs uid, transactionId and environment — never the JWS. |
| `appStoreNotifications` | **HTTPS** (v2 `onRequest`, POST `{ signedPayload }`) | App Store Server Notifications V2 (§5.1). Verifies the notification with the same verifier (`verifyAndDecodeNotification`; environment from the payload's `data.environment`). `passUpdateForNotification` (unit-tested): `REFUND` and `REVOKE` → decode `data.signedTransactionInfo`, and if it is our product, delete `passes/{transactionId}` and remove `users/{uid}.pass` **only if it still points at that transactionId** (transaction; the family the user created stays). Everything else (`TEST`, `CONSUMPTION_REQUEST`, `REFUND_REVERSED`, subscription events) is acknowledged and ignored. Responses: 200 for every verified notification, 400 for a bad signature or unreadable body (Apple retries), 405 for non-POST. Logs type, subtype, environment, notificationUUID and transactionId only. |

### 5.1 Family Pass (Stage 7)

- **Package:** `@apple/app-store-server-library` (3.1.0, Node 22 OK). Verification is fully offline: the trust anchors are Apple's three public root certificates in `functions/certs/` (`AppleRootCA-G2.cer`, `AppleRootCA-G3.cer`, `AppleIncRootCertificate.cer`; sources and re-download commands in `functions/certs/README.md`). `enableOnlineChecks` is off, so the function never calls Apple.
- **Environments:** both `Sandbox` and `Production` transactions are accepted (TestFlight and the App Review demo account buy in the sandbox). The environment is read from the unverified payload only to pick the verifier, which then rejects a payload whose signed environment or bundle id differs. `Xcode` / `LocalTesting` payloads are unsigned and rejected.
- **`APP_APPLE_ID`** (env, optional): the app's numeric Apple ID from App Store Connect → App Information. Apple's library compares it on **Production notifications** only; transactions never carry a check on it. When unset the function logs a warning and skips that one comparison (signature chain, bundle id and environment are still enforced). Set it once the App Store Connect record exists: create `firebase/functions/.env` (gitignored, so Claude re-creates it per machine) containing `APP_APPLE_ID=1234567890`, then deploy functions; the Firebase CLI loads `.env` at deploy.
- **Notification URL** to paste into App Store Connect (TESTFLIGHT §H, both Sandbox and Production fields):

  ```
  https://australia-southeast1-PROJECT_ID.cloudfunctions.net/appStoreNotifications
  ```

  2nd-gen HTTPS functions answer on this `cloudfunctions.net` URL **and** on a Cloud Run URL of the form `https://appstorenotifications-XXXXXXXXXX-ts.a.run.app` (lower-case name, random suffix), which `firebase deploy` prints as `Function URL (appStoreNotifications(australia-southeast1))`. Either works; the `cloudfunctions.net` one is predictable, so it is the one to paste. For the current project id (`.firebaserc`) that is `https://australia-southeast1-pinny-family-4vea.cloudfunctions.net/appStoreNotifications`. Test it from App Store Connect → the app → App Information → App Store Server Notifications → **Send Test Notification** (arrives as `TEST` → 200, visible in `firebase functions:log`).
- **Refund after a family was created:** the pass is removed, the family and its data stay. The user can still use the family; they just can't create another one. `REFUND_REVERSED` is ignored — the user taps **Restore purchases**, which redeems the (no longer revoked) transaction again.
- **One transaction, one account:** `passes/{transactionId}.uid` is the binding. A second account redeeming the same Apple purchase (same Apple ID, different Pinny account) gets `already-exists`. Restore on the original account is idempotent.
- **Family Sharing** is not handled: leave it off for the product in App Store Connect (the default).

### 5.2 SOS reminders (Stage 9)

iOS plays at most 30 s of one notification sound and forbids endless ones, so
the siren is 29 s and the server repeats the push until each receiver
acknowledges (writes their ack doc, §7).

- **Queue.** Deploying `sosReminder` creates the Cloud Tasks queue
  `projects/PROJECT_ID/locations/australia-southeast1/queues/sosReminder`. The
  first deploy enables `cloudtasks.googleapis.com`; if it fails with an
  API-not-enabled error, wait a minute and deploy again.
- **Enqueue.** `getFunctions().taskQueue("locations/australia-southeast1/functions/sosReminder")`
  (`firebase-admin/functions`; the `locations/…/functions/…` form is needed
  because the function is not in `us-central1`) with
  `scheduleDelaySeconds: 30`. For a 2nd-gen function the target must be its
  Cloud Run URL, so the code looks it up once per instance
  (`cloudfunctions.googleapis.com/v2beta/…/functions/sosReminder` →
  `serviceConfig.uri`, Google's documented `getFunctionUrl` helper, via
  `google-auth-library`) and passes it as `uri`; if the lookup fails it falls
  back to the SDK's default `cloudfunctions.net` URL.
- **One chain per SOS.** The task ID is `sha256(familyId/messageId/attempt)`,
  so a duplicate delivery of the Firestore trigger cannot start a second
  chain (`functions/task-already-exists` is logged at info and ignored).
- **IAM.** Functions run as the default compute service account,
  `PROJECT_NUMBER-compute@developer.gserviceaccount.com` (Pinny:
  `129139618413-compute@…`). Its default **Editor** role covers everything
  (create tasks, act as itself for the OIDC token, read the function URL,
  invoke the Cloud Run service); `onTaskDispatched` sets no `invoker`, so the
  deploy adds no IAM bindings of its own. If the log shows `could not enqueue sos reminder` with
  `PERMISSION_DENIED` (Editor was removed or never granted): Google Cloud
  console → **IAM & Admin → IAM** → that service account → add **Cloud Tasks
  Enqueuer** (`roles/cloudtasks.enqueuer`) and **Service Account User**
  (`roles/iam.serviceAccountUser`; Cloud Tasks signs the request as this
  account), plus **Cloud Functions Viewer** (`roles/cloudfunctions.viewer`)
  if the log says `could not resolve the function url`. If tasks are created
  but `sosReminder` never logs (403 in Cloud Tasks → queue → task attempts):
  **Cloud Run → `sosreminder` → Security / Permissions** → add the same
  account as **Cloud Run Invoker** (`roles/run.invoker`).
- **Check it.** After a test SOS: `firebase functions:log --only sosReminder`
  shows a `push sent` line every 30 s until everyone acked
  (`sos reminders done: nobody left to alert`) or attempt 9 ran.
- **Cost.** Cloud Tasks' free tier is 1 million operations a month; one SOS is
  at most 9 tasks (18 operations with the dispatches). Each reminder is one
  function run with about 5 Firestore reads (message, acks, sender, family
  users, tokens). Effectively free.
- **Clean-up.** Ack docs live under the message, so `purgeFamily`'s
  `recursiveDelete(chats/{familyId})` removes them. A reminder that runs after
  the purge finds no message and stops.

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
| `messageId` | not sent | the SOS message's ID (Stage 9) | Acknowledge on tap: create `chats/{familyId}/messages/{messageId}/acks/{myUid}` (§7). Identical on the first push and on every reminder. |

No other keys. Chat messages send no push in this stage.

| | Check-in | SOS |
|---|---|---|
| `apns-priority` | `5` | `10` |
| `aps.sound` | `default` | `default` |
| `aps.interruption-level` | not set (active) | `time-sensitive` |
| `apns-collapse-id` | not set | the message ID (Stage 9: a reminder replaces the earlier banner instead of stacking; omitted if the ID is over 64 bytes) |
| Repeats | no | every 30 s, up to 9 times, to members who have not acknowledged (`sosReminder`) |
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
  photoURL: string?             ≤ 2048 chars or null; the Google picture URL seeded at first
                                sign-in, or the download URL of avatars/{uid}.jpg (Stage 8, §6.1)
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
  pass: {                       Stage 7, SERVER-ONLY (redeemFamilyPass writes, appStoreNotifications removes);
    transactionId: string       clients may not create / change / delete it. Present = may create a family.
    productId: string           "com.skyline.pinny.family.pass"
    verifiedAt: timestamp       server time of the (last) redeem
  }?                            readable with the rest of the doc (owner + same family)
                                (no fcmToken — rejected since Stage 4; see pushTokens)

pushTokens/{uid}                Stage 4, owner-only (read and write); not even family
  token: string                 FCM registration token, 1–4096 chars
  updatedAt: timestamp          == server time when written

passes/{transactionId}          Stage 7, server-only (no client read or write at all)
  uid: string                   the Pinny account this Apple transaction is bound to
  productId: string             "com.skyline.pinny.family.pass"
  redeemedAt: timestamp         first redeem; unchanged by restore; deleted with the account

chats/{familyId}/messages/{messageId}
  senderId: uid
  senderName: string            1–40 UTF-16 units
  text: string                  1–1000 UTF-16 units
  type: "normal" | "sos"
  createdAt: timestamp          == server time on create

chats/{familyId}/messages/{messageId}/acks/{uid}     Stage 9: "I have seen this SOS"
  at: timestamp                 == server time on create; the only key. Doc ID = the acknowledging member's uid.
                                Create-only (own uid, family member); members read; no update / delete.
                                Only meaningful under type "sos" messages (rules don't check the parent).

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

### 6.1 Cloud Storage (Stage 8 — profile photos)

The only thing in Cloud Storage is the profile photo
([STAGE-8-CONTRACT.md](STAGE-8-CONTRACT.md)):

```
avatars/{uid}.jpg               the project's default bucket, one object per user
                                512×512 JPEG, client-resized (≈ 200 KB); rules: < 2 MB, image/jpeg
```

| | |
|---|---|
| **Bucket** | The project's default bucket (`pinny-family-4vea.firebasestorage.app`; the console shows the exact name), created once by the owner: [Firebase console → Storage](https://console.firebase.google.com/project/pinny-family-4vea/storage) → **Get started** → **Production mode** → location **`australia-southeast1`** (same region as Firestore; can't be changed later). There is no CLI to create it; until then `firebase deploy --only storage` stops with "Firebase Storage has not been set up on project 'pinny-family-4vea'" (checked 2026-09-18; the attempt also enabled the `firebasestorage.googleapis.com` API, which is harmless). Nothing else in the console needs touching. |
| **Rules** | `firebase/storage.rules`, referenced from `firebase.json` (`storage.rules`). `avatars/{file}`: **read** by any signed-in user (family faces on pins; download URLs are unguessable anyway, and family-only would need cross-service rules); **create / update** only when `file == request.auth.uid + '.jpg'`, `size < 2 MB` and `contentType == 'image/jpeg'`; **delete** by the owner only. Every other path is denied. |
| **Client** | Upload with `putData(_, metadata: contentType "image/jpeg")` to `avatars/{uid}.jpg`, then `downloadURL()` → `users/{uid}` update `{ photoURL: <url>, updatedAt: serverTimestamp() }` (§7). Remove photo: `delete()` the object (best effort) then `{ photoURL: null, updatedAt }`. |
| **Server** | `onUserDeleted` deletes `avatars/{uid}.jpg` (Admin SDK, `ignoreNotFound`). No other function touches Storage. |
| **Deploy** | `cd firebase && firebase deploy --only storage` (rules only; needs the bucket above). |
| **Tests** | `firebase/tests/storage.test.mjs` against the Storage emulator (§10). |

## 7. Client write contracts

What the iOS client writes for each action. Rules reject anything else.

| Client action | Writes (all client-side, subject to rules) |
|---|---|
| Sign in (first time) | `users/{uid}` **create**: `{ name, photoURL?, notifyOnCheckIn: true, updatedAt: serverTimestamp }`. `familyId` absent/null. `name` 1–40 UTF-16 units. No `fcmToken` key (rejected, even as `null`; remove it from the Swift `AppUser` model). |
| Save push token | `pushTokens/{uid}` **set** (whole doc) `{ token, updatedAt: serverTimestamp }` — exactly these two keys; `token` the FCM token, a non-empty string ≤ 4096 chars. **When:** on every launch once notifications are allowed, and whenever `messaging(_:didReceiveRegistrationToken:)` delivers a token — but only if the **server copy differs** (`getDocument` on `pushTokens/{uid}`: missing, or `token` ≠ the current one). Comparing with the server, not a local cache, restores a token the server removed. Only the owner can read or write it; family members can't. |
| Toggle check-in notifications | `users/{uid}` update `{ notifyOnCheckIn: Bool, updatedAt: serverTimestamp }` (`notifyOnCheckIn` a Bool; `null` or a string is rejected). Written as a **write-only transaction**, like location: it fails offline instead of sitting in the offline queue, so a failed or timed-out save is never replayed. Saves at once; on failure the toggle flips back to the user doc's value (DESIGN-SPEC §13.2). Affects check-in pushes only — SOS ignores it. |
| Sign out | **Before** `Auth.auth().signOut()` (the delete needs auth): `pushTokens/{uid}` **delete**, then `Messaging.messaging().deleteToken()` so the next account on this phone gets a new token. Best effort: if offline, sign out anyway (DESIGN-SPEC §9.6 has no error state). **Offline gap resolved server-side:** when the next account signs in on this phone and saves the same token, `onUserTokenWritten` deletes the old account's token doc, so the old family's pushes stop reaching the phone. Until someone signs in, the signed-out phone can still get them; DESIGN-SPEC §13.5 routes such a tap to the Map tab only. |
| Token removed by the server | Not a client action. `pushTokens/{uid}` is deleted by Functions when FCM reports the token invalid (§5 "Recipients and dead tokens"), when another account saves the same token (`onUserTokenWritten`), and on account deletion (`onUserDeleted`). The next launch finds the server copy missing and saves the token again. |
| Buy Family Pass (Stage 7) | StoreKit 2 `Product.purchase()` for `com.skyline.pinny.family.pass` → on `.success(.verified(transaction))` call the callable **`redeemFamilyPass`** (region `australia-southeast1`, `Functions.functions(region:)`) with `["jws": transaction.jwsRepresentation]` → on `{ ok: true }` call `transaction.finish()` and continue to Create family. `users/{uid}.pass` then appears through the profile listener. **Never write `pass` client-side** (rules reject it). Error codes → copy: `already-exists` → "This purchase is already used by another account."; `failed-precondition` / `invalid-argument` → "Couldn't confirm your purchase. Try Restore purchases."; `unauthenticated` → sign in again; anything else (network, `internal`) → "Couldn't complete the purchase. Try again." Don't `finish()` the transaction until the server said ok, so a failed redeem is retried by StoreKit's `Transaction.updates` on the next launch. |
| Restore purchases (Stage 7) | `AppStore.sync()` (optional; it prompts for the Apple ID), then `for await result in Transaction.currentEntitlements` → the verified transaction with `productID == "com.skyline.pinny.family.pass"` → the same `redeemFamilyPass` call with its `jwsRepresentation`. Same call, same errors; a pass already bound to this account is re-confirmed (idempotent). No entitlement → "No Family Pass found for this Apple ID." (client copy). |
| Create family | **Requires `users/{uid}.pass`** (Stage 7; the rules `get()` the profile, so the pass must already be there — it can't be written in the same batch, and the client can't write it at all). **One WriteBatch**: `families/{newId}` create `{ name, inviteCode, members:[uid], createdBy: uid, createdAt: serverTimestamp }` + `inviteCodes/{code}` create `{ familyId }` + `users/{uid}` update `familyId`. Generate `code` client-side (`[A-Z0-9]{6}`); if the batch fails with permission-denied the code already exists — regenerate and retry. Show the paywall first when the profile has no `pass`; a permission-denied on a profile without `pass` means the pass was refunded meanwhile — show the paywall, not a retry. |
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
| Change profile photo (Stage 8) | Storage `avatars/{uid}.jpg` **put** (JPEG, < 2 MB, `contentType: "image/jpeg"`; rules reject other names, types and sizes), then `users/{uid}` update `{ photoURL: <download URL>, updatedAt: serverTimestamp }`. `photoURL` is a string ≤ 2048 chars; a number, map or longer string is rejected. Only the owner can write either. First Google sign-in seeds `photoURL` from the Google picture URL in the create above. |
| Remove profile photo (Stage 8) | Storage `avatars/{uid}.jpg` **delete** (best effort, owner only), then `users/{uid}` update `{ photoURL: null, updatedAt: serverTimestamp }` (`FieldValue.delete()` is accepted too). |
| Delete account | `Auth.auth().currentUser?.delete()` (re-authenticate first if Firebase asks). `onUserDeleted` cleans Firestore, `pushTokens/{uid}` included, and the Storage photo `avatars/{uid}.jpg` — no client token or photo delete needed. Client should also clear local state. |
| Acknowledge an SOS (Stage 9) | `chats/{familyId}/messages/{messageId}/acks/{myUid}` **create** `{ at: serverTimestamp }` — exactly this one key; the doc ID must be the caller's own uid and the caller a current member of `{familyId}`. A device `Date`, an extra key, another member's uid or a non-member is rejected; acks can't be updated or deleted, so **a second ack of the same message is `permission-denied` — ignore it** (and `already-exists`). Write-only **transaction** like the other writes (never queued offline). **When:** (1) the user taps an SOS push — `messageId` and `familyId` are in the payload; (2) the app becomes active / the session is ready: one query `chats/{familyId}/messages` ordered by `createdAt` desc, limit 20; keep `type == "sos"`, `senderId != me`, younger than 10 min, and ack each; (3) the chat listener delivers such a message while the app is open. Effect: `sosReminder` stops re-alerting this member at its next run (≤ 30 s); the other members keep being alerted until they ack or attempt 9 has run. The sender never acks their own SOS (the server already excludes them). |

Messages cannot be edited or deleted by clients (rules: `update, delete: false`).
SOS acks (`…/acks/{uid}`) are create-only: own uid, members only, never updated or deleted by clients.
Families and invite codes cannot be deleted by clients either — server purge only.
`users/{uid}.pass` and `passes/*` are server-only (Stage 7): the client only ever
calls `redeemFamilyPass`.

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
- **SOS acks = family only, own uid only (Stage 9).**
  `chats/{familyId}/messages/{messageId}/acks/{uid}`: a current member may
  create the doc named after their own uid with exactly `{ at }` and
  `at == request.time`; members read; nobody updates or deletes. So a member
  can silence the reminders only for themselves, never for someone else, and
  an ex-member can neither read nor ack. The reminder function reads current
  members, so someone who leaves stops being alerted. Covered by the
  "stage 9: SOS acks" suite in `firebase/tests`.
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
- **Family Pass = server-verified only (Stage 7).** `users/{uid}.pass` is in
  `validUser` so ordinary profile updates still validate once it exists, but
  create rejects a `pass` key and update rejects any diff touching `pass`
  (add, change, dotted path, `null`, `deleteField`, or a full `set` that
  drops it). `passes/{transactionId}` denies all client access. `families`
  create additionally requires `get(users/{uid}).data.pass != null`, read
  before the batch, so a pass can't be smuggled in alongside the family. The
  only path to a pass is `redeemFamilyPass`, which verifies Apple's signature
  offline against Apple's root CAs. Covered by the "stage 7: family pass"
  suite in `firebase/tests`. Note: `pass` is readable by the same family
  like the rest of the profile (an Apple transaction id, not a payment
  detail); `passes/*` (uid ↔ transaction) is not readable by anyone.
- **Account deletion releases the pass.** `onUserDeleted` deletes
  `users/{uid}` (the `pass` with it) and then every `passes/*` doc with
  `uid == deletedUid` (query + batch delete), so the Apple purchase — which
  is per Apple ID — can be restored on a re-created Pinny account. Between
  deletion and the next redeem the purchase is bound to nobody; the first
  account to call `redeemFamilyPass` with it wins, which is the same rule as
  a first purchase.

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
| **Profile photo (Stage 8)** | Optional. Either the Google profile picture URL copied at first Google sign-in, or a photo the user picks from their library (`PhotosPicker`, no library access beyond the one picture), resized on the phone to 512×512 and stored as `avatars/{uid}.jpg` in the project's Cloud Storage bucket in **Sydney**, with its download URL in `users/{uid}.photoURL`. **Visible to signed-in Pinny users** (Storage read requires sign-in; the Firestore `photoURL` follows the usual owner-or-family read rule). Used only to show the face on the map pin, member rows and chat; **never used for anything else** — no face detection, no analytics, nothing leaves Firebase. Removed by "Remove photo" (object deleted, `photoURL` null) and **deleted with the account** (`onUserDeleted` deletes the object). App Store privacy label: **Photos or Videos**, linked to user, not tracking, App Functionality. |
| **Purchase (Stage 7)** | Apple handles payment; no card or Apple ID details ever reach Pinny. Stored: `users/{uid}.pass = { transactionId, productId, verifiedAt }` and `passes/{transactionId} = { uid, productId, redeemedAt }` — the Apple **transaction id** ties the purchase to the account and stops one purchase unlocking two accounts. Removed by `appStoreNotifications` on refund / revoke, and both docs are deleted on account deletion (`onUserDeleted`), so nothing about the purchase outlives the account. App Store privacy label: **Purchases → Purchase History**, linked to user, not tracking, App Functionality. |
| **Copies elsewhere** | None stored. Pushes carry no coordinates: the check-in push body may carry a saved place name ("At Home.") through FCM/APNs, but it isn't saved, and push data holds only `type`, `uid`, `familyId` and (SOS) `messageId`; chat messages store only the typed text. Functions log uids, never coordinates. **On-device cache:** the Firestore SDK keeps each member's last-seen family locations on the phone's disk (offline persistence), until overwritten by a newer snapshot or the app is deleted. Location writes don't sit in the offline write queue: the client writes them in a transaction, which fails offline and is never replayed. Open (Stage 6): call `clearPersistence()` on sign-out and account deletion so a shared or handed-down phone keeps no family locations. Firestore point-in-time recovery and backups are off (the default). Turning either on keeps past values for its retention period, so update this section if you do. |

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

`firebase/tests/` runs the rules against the Firestore and Storage emulators
with `@firebase/rules-unit-testing` and `node:test` (needs Java 11+, no real
project — uses `--project demo-familymap`). Every case in §7 has a
should-pass test and the abuse variants have should-fail tests; the database
and the bucket are cleared before each test. `rules.test.mjs` covers
`firestore.rules`, `storage.test.mjs` covers `storage.rules` (Stage 8:
owner upload / replace / delete, other uid, PNG, 3 MB, wrong name, path
outside `avatars/`, unauthenticated read).

```bash
cd firebase/tests
npm install
npm test        # = firebase emulators:exec --only firestore,storage --project demo-familymap "node --test rules.test.mjs storage.test.mjs"
```

Run it after any change to `firestore.rules` or `storage.rules`. The first run
downloads the Storage rules runtime (`cloud-storage-rules-runtime`) next to the
Firestore emulator jar.

Functions unit tests (pure check-in, Family Pass, "inside a place", SOS-body, SOS-reminder and token-change logic, no emulator, no Apple calls):

```bash
cd firebase/functions
npm test        # = npm run build && node --test test/checkin.test.mjs test/pass.test.mjs test/places.test.mjs test/sos.test.mjs test/sosReminder.test.mjs test/token.test.mjs
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

# Storage rules (§6.1; the owner creates the bucket in the console first)
firebase deploy --only storage

# Cloud Functions
cd functions && npm install && npm run build && cd ..
# optional, once the App Store Connect record exists (§5.1):
#   echo APP_APPLE_ID=1234567890 > functions/.env
firebase deploy --only functions
firebase functions:log

# Privacy + support pages (§12)
firebase deploy --only hosting

# everything
firebase deploy

# local emulators (rules + functions), no real project needed
firebase emulators:start --only firestore,storage,functions --project demo-familymap

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
