# Pinny: TestFlight release (family first)

How to get **Pinny** onto family iPhones with TestFlight. No Mac needed: everything runs from Windows and a browser.

- **Path A (main): GitHub Actions.** A GitHub-hosted Mac builds and uploads. Claude starts builds and reads the logs from this PC with `gh`.
- **Path B (alternative): Codemagic.** Sections 0 and C. `codemagic.yaml` is kept.

There is a short Mac appendix at the end, G covers the App Store release, and H covers selling the Family Pass worldwide.
Account steps (Apple, Firebase, GitHub secrets) need the owner's own logins. Claude never enters Apple or Google credentials.

| Name | Value |
|---|---|
| Home-screen name | **Pinny** (`APP_DISPLAY_NAME` in `project.yml`) |
| App Store Connect name | **Pinny Family Map** suggested (must be unique on the App Store; owner may adjust) |
| Bundle ID | `com.skyline.pinny` |
| Xcode project / target / scheme | `FamilyMap` (internal only, never shown; not renamed on purpose) |

## Path A — GitHub Actions (Claude-driven)

Two manual workflows in the private repo `skylinecarpentry1981-crypto/pinny-ios`. Nothing runs on push.

| Workflow | Runs on | What it does |
|---|---|---|
| `asc-setup.yml` (`scripts/asc_setup.py`) | Linux | Registers bundle ID `com.skyline.pinny` and turns on Push Notifications, Sign in with Apple and Time Sensitive Notifications. Counts registered iPhones and prints the app's numeric **Apple ID**, or `APP RECORD MISSING`. With `tester_email`, it adds that person to the internal TestFlight group **Owner** (access to all builds). `command=family-link` sets up external TestFlight for the family and submits the newest build for Beta App Review (section D). `command=status` is read-only. Safe to re-run. |
| `ios-testflight.yml` | macOS 26, newest Xcode 26.x | XcodeGen → archive → App Store export → checks `aps-environment = production` → uploads. Build number = run number + 100. Untick `upload` for a dry run. |

**Before you start:**
- Firebase B1–B4 and the rules deploy (section 0, steps 1–2) must be done, and the Firebase plist must be at `FamilyMap\Resources\GoogleService-Info.plist`.
- Both workflow files must be pushed to `main`, because GitHub only offers manual runs for workflows on the default branch.
You don't need A1 (App ID) or the Codemagic steps: `asc-setup` registers the App ID for you.

### Step 1 — Owner: set the four secrets (one time)

This uses your existing App Store Connect team key (the one referenced in your Expo projects' `eas.json`). Replace the three `YOUR_…` / `PATH\TO\…` placeholders, then run it in PowerShell.
The values go straight to GitHub encrypted and are never shown again. `gh secret list` shows only the names.

```powershell
Set-Location "D:\claude app project\family-map-ios"
$repo = "skylinecarpentry1981-crypto/pinny-ios"

gh secret set ASC_KEY_ID    -R $repo --body "YOUR_KEY_ID"
gh secret set ASC_ISSUER_ID -R $repo --body "YOUR_ISSUER_ID"
Get-Content -Raw "PATH\TO\AuthKey_YOUR_KEY_ID.p8" | gh secret set ASC_KEY_P8 -R $repo

$plistB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path "FamilyMap\Resources\GoogleService-Info.plist").Path))
gh secret set GOOGLE_SERVICE_INFO_PLIST_B64 -R $repo --body $plistB64

gh secret list -R $repo
```

### Step 2 onwards — the sequence

1. **Claude** runs `asc-setup`, then reads the result:
   ```powershell
   gh workflow run asc-setup.yml -R skylinecarpentry1981-crypto/pinny-ios
   gh run list -R skylinecarpentry1981-crypto/pinny-ios --workflow asc-setup.yml --limit 1   # gives <run-id>
   gh run watch <run-id> -R skylinecarpentry1981-crypto/pinny-ios --exit-status
   gh run view <run-id> -R skylinecarpentry1981-crypto/pinny-ios --log
   ```
2. **Owner**, only if `asc-setup` says so:
   - **`APP RECORD MISSING`:** in [App Store Connect](https://appstoreconnect.apple.com), go to **Apps → + → New App**. Choose iOS, name **Pinny Family Map**, bundle ID `com.skyline.pinny`, SKU `pinny-ios-1` (details in A5).
   - **`NO REGISTERED iOS DEVICES`:** register your iPhone in [Apple Developer → Devices → +](https://developer.apple.com/account/resources/devices/list) (platform iOS, name "Owner iPhone").
     The archive is signed for development first, and Apple only issues that profile when the team has at least one device.
     To find the UDID on Windows: plug in the iPhone, open **Apple Devices** or iTunes, and click the serial number on the summary until it shows **UDID**.
3. **Claude** runs the build and fixes any compile errors from the log:
   ```powershell
   gh workflow run ios-testflight.yml -R skylinecarpentry1981-crypto/pinny-ios
   gh run view <run-id> -R skylinecarpentry1981-crypto/pinny-ios --log-failed
   ```
   On failure, the "Explain the failure" step prints the raw `error:` lines verbatim, plus a plain-English diagnosis.
   The full logs and `.xcresult` are attached to the run as an artifact.
4. **Claude** runs `asc-setup` again with your App Store Connect email:
   ```powershell
   gh workflow run asc-setup.yml -R skylinecarpentry1981-crypto/pinny-ios -f tester_email=<your Apple ID email>
   ```
   This creates the internal group **Owner** and adds you to it. Internal testers must be App Store Connect users; the Account Holder already is one.
5. **Owner:** install **TestFlight** from the App Store and sign in with the same Apple ID. Install Pinny once Apple has finished processing the build.

### Troubleshooting

| Log says | Why | Fix |
|---|---|---|
| `Cloud signing permission error` (export step) | Export uses Apple's cloud-managed distribution certificate, which only works with an **Admin** API key. This key's role is unknown; App Manager keys fail here. | **Owner:** in App Store Connect, go to **Users and Access → Integrations → App Store Connect API → Team Keys → +**. Name it "GitHub Actions", Access **Admin**, then download the `.p8` (you can only download it once). Re-run the two key lines of step 1 with the new key ID and file path. The issuer ID stays the same. An Admin key can do anything an Admin can, so keep it only in GitHub secrets and revoke it if it leaks. |
| `Your team has no devices from which to generate a provisioning profile` | No registered iPhone | Step 2 above |
| `private key is not installed in your keychain` | An old runner's development certificate is still active | In Apple Developer → Certificates, revoke the **Apple Development** certificates named "Created via API". Each build normally revokes its own at the end. |
| `aps-environment is 'development'` / `No profiles for` / `doesn't include the … entitlement` | App ID capabilities don't match the entitlements | Re-run `asc-setup`. If it can't enable a capability, tick it by hand on the App ID (A1). |
| `bundle version must be higher` / `Redundant Binary Upload` | Build number already used, e.g. by a Codemagic build | Raise `BUILD_NUMBER_OFFSET` in `ios-testflight.yml` |
| Swift `error:` lines | Code | Claude fixes, pushes, re-runs |

**Why a certificate is revoked on every build:** GitHub gives each build a fresh Mac. `xcodebuild archive` therefore creates a new Apple Development certificate, whose private key vanishes with that Mac.
Left alone, these certificates pile up until Apple's limit blocks builds. The last step revokes only certificates whose private key is in that runner's own keychain, so it never touches a certificate on your own machines.
Builds already uploaded aren't affected.

**Xcode version:** since 2026-04-28, App Store Connect only accepts builds made with Xcode 26 or later ([Apple](https://developer.apple.com/news/upcoming-requirements/)).
So the workflow uses the `macos-26` runner and picks its newest Xcode 26.x. Building with the iOS 26 SDK also gives standard UI controls the new Liquid Glass look.

**Cost (private repo).** See GitHub's [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) and [runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing) pages.
- Public repos use standard runners free. A private repo draws on the account's monthly allowance, for example 2,000 minutes on GitHub Free and 3,000 on GitHub Pro.
- GitHub now states the macOS "multiplier" as a price per minute: **macOS $0.062 vs Linux (2-core) $0.006**, about 10× more.
- The billing page may show Actions usage as a dollar amount, which "already reflects any applicable minute costs".
- With no payment method on file, Actions stops once the allowance is used up; with one, any budgets you set limit the spend.
- A build is billed for its whole run time, rounded up to the minute. After the first build, check **GitHub → Settings → Billing and licensing → Usage**.
- `asc-setup` runs on Linux and costs little.

## 0. Path B (alternative): try it today with Codemagic (owner only, no review)

Goal: Pinny on the owner's own iPhone today, through TestFlight **internal testing**. There's no Beta App Review; the build appears once Apple has finished processing it. Only the minimum is below. Everything else can wait (see "Deferred").

**Required today, in this order**

1. **Firebase, on the free Spark plan (no Blaze yet):**
   - B1: create the project.
   - B2: Firestore database, location `australia-southeast1`.
   - B3: add the iOS app and download `GoogleService-Info.plist`.
   - B4: enable **Email/Password** and turn off *Email enumeration protection*. Apple sign-in is optional today; use email.
2. **Deploy rules + indexes only.** This works on Spark. Claude runs it after your OK:
   ```bash
   cd firebase
   firebase use --add          # pick the project, alias "default"
   firebase deploy --only firestore:rules,firestore:indexes
   ```
3. **Apple:**
   - A1: the App ID with all three capabilities. It's needed even today, because the app's entitlements include them and the signing profile must match.
   - A5–A6: the App Store Connect app and its numeric Apple ID.
   - A7: the API key for Codemagic.
   - Skip the A2 / A3 keys for now.
4. **Codemagic C1–C6:** repo, API key, certificate and profile, plist secret, and `APP_STORE_APPLE_ID` in `codemagic.yaml`. Skip C7.
5. **Start new build → workflow `ios-internal` → branch `main`.** It's the same build as `ios-testflight`, but it only uploads to App Store Connect: no beta review, no external group.
6. **App Store Connect → Pinny Family Map → TestFlight → Internal Testing → +**: create a group, e.g. "Owner", and add yourself. The Account Holder is already a user, so there's no invite to accept. Leave automatic distribution on if it's offered, so later builds reach you by themselves.
7. **On the iPhone:** install **TestFlight** from the App Store, sign in with the same Apple ID, and install Pinny once the build shows up. There's no encryption question: see D7.

**Honest warning: this is the app's first real compile.** The first `ios-internal` build may fail with Swift compile errors. If it does, open the failed build in Codemagic and send Claude the build log, or just the lines containing `error:`. Claude fixes the code, you push, and you start the build again. Each build takes roughly 15–30 min, so allow for a round or two.

**Deferred (the app still works without them)**

| Deferred | What you won't have yet |
|---|---|
| Blaze + Cloud Functions (B6, `functions` deploy) | **No check-in or SOS pushes.** SOS still shares your location and posts the SOS card in Chat. There's also no server clean-up yet: **Delete account** removes the sign-in only, and the Firestore data and family membership stay until Functions are deployed. A family whose last member leaves isn't purged either. So don't test Delete account on an account you care about today. |
| APNs key (A2, B5) | Pushes need it, as well as Functions. |
| Sign in with Apple key (A3) + Apple provider (B4) | Apple sign-in, and the `revokeToken` call that deleting an Apple sign-in account needs. Use email sign-in today. |
| Hosting pages + support email (B7, hosting deploy) | Only needed for external testing and the App Store. |
| External "Family" group, test information, demo accounts, Beta App Review (D1–D4, workflow `ios-testflight`) | Family installs. These come later through `ios-testflight`. |

Later, for the family: do the deferred rows, then C7–C8 with `ios-testflight`. Both workflows share one build-number sequence, so nothing needs resetting.

## A. Apple setup (owner, one time)

In [Apple Developer](https://developer.apple.com/account) → Certificates, Identifiers & Profiles:

1. **Identifiers → + → App IDs → App**: description "Pinny", bundle ID `com.skyline.pinny` (explicit). Enable these capabilities:
   **Push Notifications**, **Sign in with Apple**, **Time Sensitive Notifications**.
   They must match the app's entitlements, or the App Store profile won't sign the build.
2. **Keys → +**, "APNs": enable *Apple Push Notifications service*. Download the `.p8` (you can only download it once) and note the **Key ID**. Firebase uses it for pushes (B5).
3. **Keys → +**, "Sign in with Apple": enable it and configure it with the App ID from step 1. Download the `.p8` and note the Key ID.
   Firebase needs it for Apple sign-in and for `revokeToken` on account deletion. For the Services ID, see [BACKEND-SETUP §2](BACKEND-SETUP.md#2-authentication).
4. Note your **Team ID** (Membership page).

In [App Store Connect](https://appstoreconnect.apple.com):

5. **Apps → + → New App**: iOS; Name **Pinny Family Map**; primary language English (Australia);
   bundle ID `com.skyline.pinny`; SKU `pinny-ios-1` (internal only, never shown); user access: Full.
   - The App Store Connect **Name** has to be unique across the whole App Store. It's what TestFlight and a future store listing show.
   - The **home-screen name** comes from the app itself ("Pinny") and can differ from it.
   - If "Pinny Family Map" is taken, try another. The home-screen name stays Pinny.
6. Open the app → **App Information** → copy the numeric **Apple ID** (used in C6).
7. **Users and Access → Integrations → App Store Connect API → Team Keys → +**: name "Codemagic", role **App Manager**.
   Download the `.p8` (only once) and note the **Issuer ID** and **Key ID**. The first time, the Account Holder has to click *Request Access*.

## B. Firebase setup (owner, one time)

Full detail is in [BACKEND-SETUP.md](BACKEND-SETUP.md). The short version:

1. [Firebase console](https://console.firebase.google.com) → **Add project** `pinny-YOURSUFFIX` (new project, not NOGADA's; Analytics off).
   The project ID appears in the public privacy page URL.
2. **Firestore → Create database**: Production mode, location **`australia-southeast1`**. The location can't be changed later.
3. **Project settings → Add app → iOS**: bundle ID `com.skyline.pinny`, nickname "Pinny iOS". Download **`GoogleService-Info.plist`**.
   It's a secret: never commit it (it's already gitignored).
4. **Authentication → Sign-in method**: enable **Email/Password** and **Apple** (details from A3).
   Then **Settings → User actions**: turn **off** *Email enumeration protection*.
5. **Project settings → Cloud Messaging → Apple app configuration**: upload the APNs `.p8` from A2 with its Key ID and Team ID.
6. Upgrade to the **Blaze** plan, which Cloud Functions need. Blaze keeps the same no-cost usage allowance as the free plan, and a family-sized app should normally stay inside it. Still set a budget alert (Billing → Budgets) so any charge is flagged.
7. Choose the **support email**. Claude replaces `SUPPORT_EMAIL` in `firebase/hosting/privacy.html` and `support.html` with it.
8. Deploy. The Firebase CLI on this PC is already logged in as the owner, but Claude still asks before each deploy:
   ```bash
   cd firebase
   firebase use --add          # pick the project, alias "default"
   firebase deploy --only firestore:rules,firestore:indexes,functions,hosting
   ```
   This publishes the privacy policy at `https://PROJECT_ID.web.app/privacy` and support at `https://PROJECT_ID.web.app/support`.
   Functions run on `nodejs22`, which Google supports until 2027-10-31.

## C. Path B (alternative): build with Codemagic

Use this only if Path A is blocked. If you switch between the two paths, the build numbers must keep rising: Codemagic uses the latest TestFlight build + 1, and Path A uses run number + `BUILD_NUMBER_OFFSET`.

1. Push this folder to a **private** GitHub repo. `GoogleService-Info.plist`, `*.xcodeproj` and keys are gitignored.
2. [Codemagic](https://codemagic.io) → sign up with GitHub → **Add application** → choose the repo. It reads `codemagic.yaml` from the repo root.
3. **Team settings → Team integrations → Developer Portal → Manage keys → Add key**: name it **`asc_api_key`** (must match `codemagic.yaml`), then add the Issuer ID, Key ID and `.p8` from A7.
4. **Team settings → codemagic.yaml settings → Code signing identities**:
   - **iOS certificates → Generate certificate**: *Apple Distribution*, using the key from step 3. Download it straight away (you only get one chance) and keep it safe. Apple allows only 3 distribution certificates.
   - In Apple Developer → **Profiles → +** → *App Store Connect*: App ID `com.skyline.pinny`, with the certificate you just generated. Name it "Pinny App Store".
   - Back in Codemagic: **iOS provisioning profiles → Fetch profiles** → pick "Pinny App Store".
5. **App → Environment variables**: group **`firebase_ios`**, variable **`GOOGLE_SERVICE_INFO_PLIST`**, tick **Secret**. For the value, run this in PowerShell in the folder with the plist; it copies the base64 to the clipboard:
   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("GoogleService-Info.plist")) | Set-Clipboard
   ```
6. In `codemagic.yaml`, replace `APP_STORE_APPLE_ID: 0000000000` with the Apple ID from A6 (Claude can do this). Commit and push.
7. Do D1 and D2 first, so the **Family** group and test information exist.
8. **Start new build** → workflow **`ios-testflight`** → branch `main`. The build:
   - generates the Xcode project with XcodeGen and signs it
   - sets the build number to the latest TestFlight build + 1
   - fails if the IPA's push environment isn't `production`
   - uploads the build and submits it for beta review

   Builds only start by hand, so pushes to GitHub don't use build minutes.

**Push environment:** `project.yml` keeps `aps-environment = development` so Debug runs sign with a development profile.
The App Store export re-signs it to `production`, which TestFlight uses, and step C8 checks it.
Hardcoding `production` would break Debug signing, so it isn't done.

## D. TestFlight for the family

**One command (Path A).** After a build has been uploaded and processed (`status` shows it as `VALID`), Claude runs:

```powershell
gh workflow run asc-setup.yml -R skylinecarpentry1981-crypto/pinny-ios -f command=family-link -f contact_phone=<owner phone> -f contact_first_name=<first> -f contact_last_name=<last>
```

`family-link` (`scripts/asc_setup.py`) does D1, D2 and D4 in one go and is safe to re-run:

- creates the external group **Family** with a **public link** on (no tester limit, feedback on), or reuses it, and prints `PUBLIC LINK: https://testflight.apple.com/join/…`;
- writes the TestFlight test information (en-AU; an existing en-US entry is updated instead): what to test, feedback email `tony810704@hotmail.com`, privacy policy URL `https://pinny-family-4vea.web.app/privacy`;
- writes the Beta App Review contact (email, plus the name and phone from the inputs; needed once, never printed) and the review notes ("Sign in with your own Google or Apple account. Creating a family needs the Family Pass in-app purchase; in TestFlight/sandbox this is free. Location is shared only while the app is open …"), with *demo account required: no*;
- takes the newest processed build (or `-f build=<number>`), sets its What to Test text, answers export compliance (`usesNonExemptEncryption = false`) if the build still asks, adds it to **Family**, submits it for Beta App Review, and prints `BETA REVIEW STATE: WAITING_FOR_REVIEW | IN_REVIEW | APPROVED | REJECTED`.

`gh workflow run asc-setup.yml -R skylinecarpentry1981-crypto/pinny-ios -f command=status` shows the public link and the latest build's review state at any time.

**Sharing with the family:** once the state is `APPROVED`, send everyone the public link. They install **TestFlight** from the App Store, open the link and tap Accept: no Apple ID emails to collect, no developer-team membership, and they never see App Store Connect.

The manual equivalents, for reference:

1. **External group "Family".** App Store Connect → Pinny Family Map → **TestFlight → External Testing → +** → "Family" → enable the public link. (Or add each person's name and Apple ID email; they get an email invite instead.)
2. **Test Information** (TestFlight → Test Information), needed before the first external build:
   - Beta description, feedback email, and **Privacy Policy URL** = `https://PROJECT_ID.web.app/privacy` (B8). External testing requires it.
   - **Sign-in required: no** (testers use their own Google or Apple account). The review notes explain the Family Pass and that location is shared only while the app is open.
3. **Demo account + demo family** are not needed for Beta App Review (the notes say sign-in is with the tester's own account), but they are for the App Store review in G6 / H9. Never use real family accounts:
   - Create two email/password accounts in Pinny with addresses you control, e.g. `review1@…` and `review2@…`.
   - Account 1 creates the family "Review Family". Account 2 joins it with the invite code and shares a location once, so the map shows a pin.
   - Add one saved place ("Home") so the "At Home" label can be seen.
4. The **first build goes to Beta App Review**, which is usually quick. After approval, the build becomes available to the group. Later builds of the same version may skip a full review.
   - **Path A:** `family-link` above. By hand: in App Store Connect → TestFlight, open the build and add the **Family** group; that asks you to submit it for Beta App Review.
   - **Path B:** Codemagic's `ios-testflight` workflow submits the build and adds it to `Family` (`beta_groups`).
5. **Faster alternative: Internal testing** (Path A as is, or Codemagic `ios-internal`). No review, and a build is available minutes after processing. But every tester has to be added to your App Store Connect team with a role (up to 100 people), so each family member gets an App Store Connect login. That's fine for one technical helper; for the family, External is simpler.
6. **Builds expire after 90 days.** Start a new build before then (Path A: `ios-testflight`). Testers are notified and update in TestFlight.
7. **Export compliance** is pre-answered: `ITSAppUsesNonExemptEncryption = false` is in `Info.plist`, so App Store Connect won't ask about encryption on each build.

## E. Privacy manifest and pages

- `FamilyMap/Resources/PrivacyInfo.xcprivacy` declares no tracking, and eight collected data types: Precise Location, Name, Email Address, User ID, Device ID (the push notification token, declared to be safe), Other User Content (chat), Other Data (battery) and Photos or Videos (the optional profile photo, Stage 8). All are linked to the user, used for App Functionality, and not used for tracking.
  - It declares no required-reason APIs, because our Swift uses none today. Re-check before each release, e.g. if `UserDefaults` / `@AppStorage` is added, declare `CA92.1`.
  - Firebase ships its own manifests.
- `firebase/hosting/privacy.html` and `support.html` restate [BACKEND-SETUP §9](BACKEND-SETUP.md#9-location-data-privacy). If the data model changes, update both in the same change.

## F. Checklist

| # | Step | Who | Status |
|---|---|---|---|
| PA1 | Path A: `ios-testflight.yml`, `asc-setup.yml`, `scripts/asc_setup.py`; `DEVELOPMENT_TEAM` X86UHCK734 in `project.yml` | Claude | Done |
| PA2 | Path A: Firebase on Spark B1–B4 + rules/indexes deploy (same as 0b, 0c) | Owner; Claude after OK | Done (project `pinny-family-4vea`, Sydney; rules deployed) |
| PA3 | Path A step 1: set the four GitHub secrets | Owner | Done |
| PA4 | Run `asc-setup`: bundle ID + capabilities, device count, Apple ID | Claude | Done (Apple ID 6813281782, 1 device) |
| PA5 | If reported: create the App Store Connect app record; register an iPhone | Owner | Done (Pinny Family Map) |
| PA6 | Run `ios-testflight`; fix Swift errors from the log; if "Cloud signing permission error", owner makes an Admin key and re-sets 2 secrets | Claude; Owner | Done (build 103 uploaded 2026-09-18; 1 compile fix) |
| PA7 | Run `asc-setup` with `tester_email` (internal group "Owner") | Claude | Group created; API refuses to add the Account Holder (409) → owner adds themself in TestFlight › Internal Testing › Owner |
| PA8 | Install Pinny via the TestFlight app | Owner | To do |
| 0a | Path B fast path: `ios-internal` workflow in `codemagic.yaml` | Claude | Done |
| 0b | Fast path: Firebase on Spark, B1–B4 (Email/Password only, enumeration protection off) | Owner | To do |
| 0c | Fast path: deploy rules + indexes only (`firebase deploy --only firestore:rules,firestore:indexes`) | Claude, after owner OK | To do |
| 0d | Path B only: A1 App ID, A5–A7 App Store Connect app, Apple ID, API key | Owner | Not needed for Path A |
| 0e | Path B only: C1–C5 GitHub + Codemagic; C6 `APP_STORE_APPLE_ID` | Owner; Claude (C6) | Not needed for Path A |
| 0f | Path B only: run `ios-internal`; fix any Swift compile errors from the log and rebuild | Owner → Claude | Not needed for Path A |
| 0g | Path B only: Internal Testing group with yourself → install via the TestFlight app | Owner | Not needed for Path A |
| 1 | `project.yml` (Pinny, `com.skyline.pinny`, versions, scheme, manifest), `codemagic.yaml`, `.gitignore` | Claude | Done |
| 2 | `PrivacyInfo.xcprivacy`, Hosting `privacy.html` / `support.html`, `firebase.json` hosting | Claude | Done |
| 3 | App icon (`AppIcon-1024.png`) | Designer | Done |
| 4 | Rename Swift strings "FamilyMap" → "Pinny" (see list below) | Frontend | Done |
| 5 | A1–A4 App ID + APNs / SIWA keys | Owner | To do |
| 6 | A5–A7 App Store Connect app, Apple ID, API key | Owner | To do |
| 7 | B1–B6 Firebase project, auth, APNs, Blaze | Owner | To do |
| 8 | B7 support email → fill `SUPPORT_EMAIL` | Owner → Claude | Done (tony810704@hotmail.com; hosting deployed) |
| 9 | Functions runtime → `nodejs22` | Claude | Done |
| 10 | B8 deploy rules, functions, hosting (`firebase deploy --only …,hosting`) | Claude, after owner OK | To do |
| 11 | Path B only: C1–C5 GitHub + Codemagic key, certificate, profile, plist secret | Owner | Not needed for Path A |
| 12 | Path B only: C6 set `APP_STORE_APPLE_ID` (the ID `asc-setup` prints) | Claude | Not needed for Path A |
| 13 | D1–D2 Family group + public link, test information + privacy URL, review contact/notes (`asc-setup` `command=family-link`) | Claude (owner gives contact name + phone once) | To do |
| 14 | First external build → Beta App Review → family installs via the public link (`family-link` submits it, D4) | Claude; Owner shares the link | To do |
| 15 | New build before the 90-day expiry | Owner / Claude | Ongoing |
| H0 | Stage 7 backend: rules (`pass`, `passes`, family create gate), `redeemFamilyPass`, `appStoreNotifications`, Apple root certs, tests | Claude | Done |
| H1 | Paid Apps Agreement: agree, bank account, tax forms, contact info → status Active | Owner (Account Holder) | Done (already active from earlier apps) |
| H2 | Create the non-consumable IAP `com.skyline.pinny.family.pass` (the first attempt `…familypass` was created as Consumable by mistake; deleted IDs can't be reused) (price A$14.99, localisation, review screenshot) | Owner | To do |
| H3 | Attach the IAP to the first App Store version | Owner | To do |
| H4 | App Store Server Notifications URL (Sandbox + Production, V2) → send test notification; Claude checks the log | Owner → Claude | To do |
| H5 | Give Claude the numeric Apple ID → `APP_APPLE_ID` in `functions/.env` → redeploy functions | Owner → Claude | To do |
| H6 | Sandbox test in TestFlight: buy, restore, refund | Owner | To do |
| H7 | Small Business Program enrolment | Owner | Done (already enrolled) |
| H8 | Pricing and Availability: Free app, all countries | Owner | To do |
| H9 | Demo account buys the pass in the sandbox; review notes updated | Owner | To do |
| H10 | Deploy Stage 7 rules + functions + hosting (privacy page) — before H4/H6 | Claude, after owner OK | To do |
| S8a | Stage 8 backend: `storage.rules` + `firebase.json`, `photoURL` rules tests, Storage rules tests, `onUserDeleted` photo clean-up, docs + privacy page | Claude | Done |
| S8b | Create the Storage bucket once: Firebase console → Storage → Get started → Production mode → `australia-southeast1` ([BACKEND-SETUP §6.1](BACKEND-SETUP.md#61-cloud-storage-stage-8--profile-photos)) | Owner | To do |
| S8c | Deploy Stage 8: `firebase deploy --only storage,functions,hosting` (Storage rules, `onUserDeleted`, privacy page) — after S8b | Claude, after owner OK | To do |

## G. Later: App Store release

This isn't needed for TestFlight. To go public, add the following in App Store Connect → the app's version page:

Claude fills items 1, 3, 4 and 6 (URLs, texts, categories, age rating, copyright, manual release, App Review contact + notes; texts from [APP-STORE-LISTING.md](APP-STORE-LISTING.md)) with one run — safe to repeat, the phone is needed once and is never printed. It never submits, attaches a build, or touches pricing, availability or screenshots; those, the App Privacy answers (5) and **Add for Review** (8) stay manual:

```
gh workflow run asc-setup.yml -R skylinecarpentry1981-crypto/pinny-ios -f command=listing -f contact_phone=+61400000000
```

1. **Privacy Policy URL** and **Support URL**: the two Hosting pages (B8).
2. **Screenshots**: iPhone **6.9"** and **6.5"** sets. Without a Mac, take them on a family member's Pro Max-size iPhone running the TestFlight build, using the demo family (no real locations).
3. **Description, keywords, subtitle** and a category.
4. **Age rating** questionnaire.
5. **App Privacy** answers, matching `PrivacyInfo.xcprivacy` exactly. All are linked to the user, not used for tracking, App Functionality:

   | App Store Connect category | Data type | What it is in Pinny |
   |---|---|---|
   | Location | Precise Location | last shared location, saved places |
   | Contact Info | Name | display name |
   | Contact Info | Email Address | sign-in email |
   | Identifiers | User ID | Firebase user ID |
   | Identifiers | Device ID | push notification (FCM) token |
   | User Content | Other User Content | family chat messages |
   | Other Data | Other Data Types | battery level, charging state |
   | Purchases | Purchase History | Family Pass: Apple transaction id tied to the account (H) |
   | User Content | Photos or Videos | optional profile photo (`avatars/{uid}.jpg`, Stage 8; [BACKEND-SETUP §9](BACKEND-SETUP.md#9-location-data-privacy)) |
6. **App Review information**: the same demo account + demo family as D3, a contact phone/email, and notes saying location is shared only while the app is open (open, Refresh / Check in, SOS), with no background tracking. The demo account must already hold a Family Pass (H9).
7. Already in place: in-app account deletion (Guideline 5.1.1(v)), Sign in with Apple next to email sign-in, "When In Use" location only, and the export compliance flag.
8. Pick a build → **Add for Review** → release manually after approval.

## H. Selling: Family Pass + worldwide release (owner steps)

Stage 7 ([STAGE-7-CONTRACT.md](STAGE-7-CONTRACT.md)): one non-consumable in-app purchase, **Family Pass**, unlocks "Create family". Joining is free. Apple takes the payment; the server verifies it ([BACKEND-SETUP §5.1](BACKEND-SETUP.md#51-family-pass-stage-7)). Do these in order; H1 gates everything else.

| Name | Value |
|---|---|
| Product ID | `com.skyline.pinny.family.pass` (fixed in the app and the server; can't be changed after creation) |
| Type | Non-Consumable |
| Reference name (internal) | `Family Pass` |
| Display name (App Store, English) | `Family Pass` |
| Description (App Store, English) | `Create a family and invite everyone with a code. One-time purchase, no subscription.` |
| Price | A$14.99 → Apple's nearest **price point** (Apple shows them per country; pick the A$14.99 one). Prices in every other country are set automatically from that base and shown to the user by the app (`displayPrice`). |
| Family Sharing | leave **off** (default). |

1. **Paid Apps Agreement** (Account Holder only). App Store Connect → **Business** (older UI: Agreements, Tax, and Banking) → **Paid Apps** → *View and Agree to Terms*. Then, in the same place, add **Bank Account** (the business account Apple pays into; BSB + account number, AUD), **Tax Forms** (Australian entity: the tax questionnaire + a US W-8BEN-E for the American store; ABN and GST status are asked here) and **Contact Info** (senior management, financial, technical, legal — you can be all four).
   The agreement status must be **Active** before a purchase works, even in the sandbox. Apple usually takes a day or two after the forms are in.
2. **Create the product.** App Store Connect → Pinny Family Map → **Monetization → In-App Purchases → +** → *Non-Consumable*, reference name and product ID from the table above.
   Then on the product page:
   - **Availability**: all countries or regions (default).
   - **Price Schedule → Add Pricing**: base country Australia, pick the A$14.99 price point → Apple fills in the other 174 storefronts. Confirm.
   - **App Store Localization → +** → English (Australia): display name and description from the table. Add **English (U.S.)** with the same text if the form asks for the app's primary language.
   - **Review Information**: a screenshot of the paywall (H6 gives you a build; any iPhone screenshot of the paywall is fine, it isn't shown to users) and a note: "One-time purchase that unlocks creating a family. Joining a family with a code is free."
   - Save. Status becomes *Ready to Submit*.
3. **Attach it to the version.** On the app version page (G), section **In-App Purchases and Subscriptions** → + → tick Family Pass. The product is reviewed together with the first version that includes it; after that it stays approved.
4. **Server Notifications URL.** App Store Connect → the app → **App Information → App Store Server Notifications**: set **Production Server URL** *and* **Sandbox Server URL** to the same value, **Version 2** for both:
   `https://australia-southeast1-PROJECT_ID.cloudfunctions.net/appStoreNotifications`
   (with the real project id: `https://australia-southeast1-pinny-family-4vea.cloudfunctions.net/appStoreNotifications`). The function must be deployed first (F row 10). Click **Send Test Notification** (Sandbox) → Claude checks `firebase functions:log` for `app store notification … type: "TEST"`. This is what removes a pass after a refund.
5. **`APP_APPLE_ID`** (optional hardening): copy the app's numeric **Apple ID** (App Information → General Information) to Claude, who writes `APP_APPLE_ID=<number>` into `firebase/functions/.env` and redeploys functions. Without it the server still verifies Apple's signature, bundle id and environment; it only skips comparing the app id on production notifications.
6. **Test in TestFlight (sandbox = free).** Purchases in a TestFlight build use the sandbox: no money moves, and the Apple ID signed into the App Store gets a sandbox purchase sheet. Optional but tidier: **Users and Access → Sandbox → Test Accounts → +** to make a dedicated sandbox Apple ID, then on the iPhone **Settings → App Store → Sandbox Account** sign in with it (only appears after the first sandbox purchase attempt). What to check: buy → "You're all set" → Create family works; delete the app, reinstall, **Restore purchases** → pass back; **Settings → Sandbox Account → Manage** lets you clear purchase history to buy again. A refund can be simulated from that same Manage screen (**Refund Purchases**) → within a minute the Server Notification arrives → the pass row shows "Not purchased".
7. **Apple Small Business Program** (15 % commission instead of 30 %). [developer.apple.com/app-store/small-business-program](https://developer.apple.com/app-store/small-business-program/) → *Enroll* with the Account Holder Apple ID, once the Paid Apps Agreement is active. It applies from the next month; you must list any associated developer accounts (none).
8. **Worldwide availability.** App Store Connect → the app → **Distribution → Pricing and Availability**: app price **Free** (the Family Pass is the only charge), **Availability → All countries or regions**. Pre-orders off. Tax and pricing consequences: Apple collects and remits VAT / sales tax in each storefront, and your proceeds report (Payments and Financial Reports) is per country — nothing to do in the app. Some countries need extra declarations (e.g. Korea, China: none required for a Free app with an IAP that Apple sells).
9. **App Review demo account with a pass.** App Review must be able to press "Create family" without paying. On a TestFlight build, sign in as the demo account (D3, `review1@…`) and buy the Family Pass in the **sandbox** (H6) — the server accepts sandbox purchases as real passes, so the demo account now holds a pass permanently. Then in **App Review Information → Sign-in Information** give that account's email + password and add to the notes: "The demo account already holds the Family Pass (one-time in-app purchase that unlocks creating a family). Joining a family with an invite code is free. To see the paywall, sign up with a fresh account and tap Create family." Also fill **In-App Purchase** review info if the form asks (same sentence).
10. **Privacy page and App Privacy answers**: `privacy.html` already states purchase data (Apple transaction id), worldwide availability and Sydney storage; the G5 table gains the **Purchases → Purchase History** row. Nothing else changes.

Copy rules for the listing and the IAP text (contract §4): no "free trial", no "subscription" — it's a one-time purchase tied to the Apple ID.

## Appendix: with a Mac (optional)

1. `brew install xcodegen`, then `xcodegen generate` in the repo. Copy `GoogleService-Info.plist` into `FamilyMap/Resources/`.
2. Open `FamilyMap.xcodeproj` → target FamilyMap → Signing & Capabilities → choose your Team (automatic signing).
3. Raise `CURRENT_PROJECT_VERSION` in `project.yml` above the latest TestFlight build, then regenerate.
4. **Any iOS Device** → **Product → Archive** → **Distribute App → App Store Connect → Upload**. Then continue at D.

## Appendix: where the name appears

To rename the app, change **`APP_DISPLAY_NAME`** in `project.yml`. It feeds `CFBundleDisplayName` and the location permission text via `$(APP_DISPLAY_NAME)`.
Other places:

- **Store / services:** App Store Connect Name, Firebase app nickname, Hosting pages (`firebase/hosting/*.html`), this file.
- **Swift, user-facing (Frontend to rename):**
  - `Features/Auth/WelcomeView.swift:60` (title)
  - `Features/Settings/SettingsView.swift:76` (privacy text, "open FamilyMap")
  - `Features/Settings/SettingsView.swift:141` (version row)
  - `DesignSystem/Components/InviteCodeCard.swift:10` (invite share text)
- **Swift, internal (leave):**
  - `App/FamilyMapApp.swift` (type name)
  - `App/AppDelegate.swift:8` (notification name)
  - `Core/Services/LocationSync.swift:71` (queue label)
  - `DesignSystem/Theme.swift:5` and `Features/Family/PlaceSearchModel.swift:5` (comments)
