# Pinny — App Store listing (1.0, worldwide, English)

Paste-ready copy for App Store Connect. Contract: STAGE-7-CONTRACT.md. Owner steps for the listing: TESTFLIGHT.md §G. Replace `PROJECT_ID` with the Firebase project ID (BACKEND-SETUP §12). Character limits are Apple's; counts are given so nothing gets cut.

## 1. Product page

| Field | Value | Limit |
|---|---|---|
| Name | `Pinny` | 30 |
| Subtitle | `Family map, SOS and chat` (24) | 30 |
| Primary category | Social Networking | |
| Secondary category | Utilities | |
| Support URL | `https://PROJECT_ID.web.app/support` | |
| Privacy Policy URL | `https://PROJECT_ID.web.app/privacy` | |
| Marketing URL | leave empty | |
| Copyright | `2026 Skyline Carpentry Pty Ltd` (owner to confirm the legal entity) | |
| Availability | all territories; price Free (the Family Pass is the only charge) | |
| Age rating | 4+ (§3) | |

**Promotional text** (editable without a new build; 170 max — 134):

```
See where your family is the moment they open Pinny, hold to send an SOS, and chat in one private place. No background tracking, ever.
```

**Keywords** (100 max — 99; no spaces after commas, no words already in the name or subtitle):

```
locator,location,sharing,find,kids,parents,teens,safety,places,checkin,emergency,GPS,circle,tracker
```

## 2. Description (4000 max — about 1900)

```
Pinny is a private map for your family. Open the app and you see everyone who has shared their location — with the time they shared it and how much battery they have left. That's it. No feeds, no strangers, no ads.

HOW PINNY SHARES LOCATION
Pinny shares your location with your family only when you open the app, tap Refresh or Check in, or send an SOS. It never tracks you in the background, and it never shares with anyone outside your family. Everyone can see exactly what is shared, right on the map.

SOS
One big red button on the map. Hold it for a moment and everyone in your family gets an alert with your location. The alert can't be muted, and straight after there's a call button that shows your region's emergency number.

FAMILY CHAT
A simple group chat for your family only. Messages stay inside your family.

PLACES
Save Home, School, Work or Grandma's. When someone checks in from a saved place, the alert says where — "At School" — instead of a street address.

MEMBER DRAWER
Swipe up from the map to see everyone at a glance: who's where, when they last shared, and their battery level. Tap a name to open directions in Maps, message them or check in.

FAMILY PASS
Creating a family needs a Family Pass — a one-time purchase, tied to your Apple ID. Only the person who creates the family needs it. Everyone else joins free with the family's invite code, and there's no limit on how many people can join.

PRIVACY
• Location is shared only when you open Pinny, tap Refresh or Check in, or send an SOS.
• No background tracking, no location history, no selling of data.
• Sign in with Apple, Google or email.
• Delete your account and your location data from inside the app at any time.

Pinny is made for one family per account: parents, kids with their own phones, grandparents, housemates — anyone you'd want to find in a hurry.
```

## 3. Age rating

Answer the questionnaire as follows; expected result **4+**.

| Question | Answer |
|---|---|
| Cartoon or fantasy violence / realistic violence / prolonged graphic violence | None |
| Profanity or crude humour | None |
| Mature or suggestive themes / sexual content or nudity / horror or fear themes | None |
| Alcohol, tobacco or drug use or references | None |
| Medical or treatment information | None |
| Gambling, simulated gambling, contests | None |
| Unrestricted web access | No (the app opens only its own support and privacy pages) |
| Messaging / user-generated content | Yes — text chat between members of one invite-only family; no public content, no discovery of other users |
| Made for Kids | No |

Notes for the questionnaire: the SOS feature and its call button (which shows your region's emergency number — 000, 911, 999, 112 and so on) are a safety feature, not restricted content — it opens the phone dialler with the system's own call confirmation and shows no violent, medical or fear-based content. Family chat is limited to people who hold the family's invite code, so it is not open messaging. If the questionnaire asks about location sharing, answer that location is shared with the user's own family only, when the app is open.

## 4. App Privacy

Use the TESTFLIGHT.md §G table (all linked to the user, not used for tracking, App Functionality) **plus one row for Stage 7:**

| App Store Connect category | Data type | What it is in Pinny |
|---|---|---|
| Purchases | Purchase History | the Family Pass transaction ID, stored with the account to unlock creating a family |

## 5. What's New in 1.0

```
Welcome to Pinny — a private map for your family.
• See your family on one map, shared only when they open the app
• SOS: hold one button and everyone is alerted with your location
• Family chat and saved Places like Home and School
• Family Pass: one purchase to create your family; everyone else joins free
```

## 6. Screenshots — iPhone 6.9" (1320 × 2868), 6 shots

Use the demo family (TESTFLIGHT §D3) with fake locations; light mode; Dynamic Type default; status bar 9:41, full battery. Caption is set in the screenshot image, `.largeTitle` bold, top 20 %, on `#F2F2F7`; device frame below. Export the same six at 6.5" (1284 × 2778).

| # | Screen | Caption |
|---|---|---|
| 1 | Map home — 4 pins, drawer at half, one member selected | `Your family, one tap away` |
| 2 | Member drawer full — names, "Updated 2 min ago", battery, place line | `Who's where, at a glance` |
| 3 | SOS confirm sheet — ring half-filled on the hold button | `Hold to send an SOS` |
| 4 | Chat — a short family thread with an SOS card | `A chat that's just your family` |
| 5 | Place editor — "School", 200 m radius on the map | `Places like Home and School` |
| 6 | Family Pass paywall — Ready state, price visible | `One pass. Everyone joins free.` |

Shot 1 is the one that shows in search; shot 6 must show the real StoreKit price so it matches the IAP review screenshot (§8).

## 7. App Review notes

Reviewer notes (paste in App Review Information → Notes):

```
Demo account (email sign-in): review@PROJECT_ID.web.app / [password in App Store Connect only]
This account already holds a Family Pass and is in a demo family with three members and fake locations, so every screen has content.

LOCATION: Pinny reads location only while the app is open — on launch, when the user taps Refresh or Check in, or when sending an SOS. There is no background location, no significant-change monitoring and no location history. The permission is "When In Use" only.

FAMILY PASS (in-app purchase, non-consumable): only creating a family requires it. To see the paywall, sign out, sign in with a new Apple ID or email, and tap "Create family". To test the purchase in the sandbox, use a sandbox Apple ID. "Restore purchases" is on the paywall and in Settings > Family Pass. The demo account shows Settings > Family Pass > Active.

JOINING IS FREE: a second account can join the demo family with invite code [CODE] with no purchase.

SOS: after an SOS is sent, a call button shows your region's emergency number (taken from the device region: 911 in the US, 000 in Australia, 999 in the UK, 112 elsewhere) and opens the phone dialler; nothing is dialled without the system confirmation. Sending an SOS only posts a message and a push to the demo family.

ACCOUNT DELETION: Settings > Delete account (Guideline 5.1.1(v)).
Sign in with Apple is offered alongside Google and email (Guideline 4.8).
```

Contact: the owner's phone and email. Attach nothing else; the IAP has its own screenshot (§8).

## 8. In-App Purchase listing

| Field | Value | Limit |
|---|---|---|
| Type | Non-Consumable | |
| Reference name | `Family Pass` | 64 |
| Product ID | `com.skyline.pinny.family.pass` | |
| Price | owner picks the tier nearest A$14.99; Apple converts for other storefronts | |
| Availability | all territories | |
| Display name (en-AU / en-US) | `Family Pass` | 30 |
| Description | `Create your family's private map on Pinny` (41) | 45 |
| Review screenshot | paywall in the Ready state (screenshot 6, without caption; any iPhone size Apple accepts) | |
| Review notes | see below | |

IAP review note:

```
One-time, non-consumable purchase that lets the buyer create a family in Pinny. Joining an existing family with an invite code is free and needs no purchase. The purchase is verified on our server (App Store Server API JWS verification) and tied to the buyer's Apple ID; Restore purchases is available on the paywall and in Settings. The demo account already holds the pass, so use a new account to see the paywall.
```

Submit the IAP with the 1.0 version (it can't be reviewed alone before the first version). The Paid Apps Agreement must be signed by the Account Holder first, or the product never loads in the app.

## 9. Open items for the owner

1. ~~`Call 000` hard-coded for a worldwide release.~~ Decided: the emergency number follows the device region (DESIGN-SPEC §13.3). Frontend implements it; the copy above already says "your region's emergency number".
2. Don't forget the extra App Privacy row in §4 (Purchases › Purchase History) — it is new in 1.0 and is not in the TESTFLIGHT §G table.
3. Confirm the copyright entity and the support email on the hosted support page.
4. Fill in the demo password, the invite code and the contact details in App Store Connect only — never in this repo.
