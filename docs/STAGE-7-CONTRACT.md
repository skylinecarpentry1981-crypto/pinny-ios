# Stage 7 — Family Pass (in-app purchase) + worldwide App Store release

Owner decisions (2026-09-18): sell Pinny to everyone, worldwide. Distribution = **public App Store listing, all territories**, English UI (other languages later). Payment = Apple **In-App Purchase** (StoreKit 2); Apple Pay cards work through the normal App Store payment sheet. This contract is the single source of truth for Designer, Frontend, Backend and Overseer.

## 1. Product

- One **non-consumable** IAP: product id `com.skyline.pinny.family.pass`, display name "Family Pass", reference price tier ≈ A$14.99 (owner sets the exact tier in App Store Connect).
- **One purchase unlocks one family.** Only the person who **creates** a family needs the pass. Joining with an invite code is free and unlimited.
- The pass is tied to the purchaser's Apple ID (Apple rule). Restore purchases must work (Apple requirement).
- No subscription, no trial, no other products in Stage 7.

## 2. Gating (deny by default, server-verified)

- `users/{uid}.pass` = `{ transactionId: string, productId: string, verifiedAt: timestamp }` — **written only by the server** (rules deny any client write to `pass`).
- `families` create rule additionally requires `get(users/$(uid)).data.pass != null`.
- Everything else stays free: join, map, chat, SOS, places.
- Flow: app buys via StoreKit 2 → app calls callable Cloud Function `redeemFamilyPass({ jws })` with `transaction.jwsRepresentation` → function verifies the JWS offline with `@apple/app-store-server-library` (`SignedDataVerifier`, bundle id `com.skyline.pinny`, Apple root CAs bundled, environment Sandbox or Production from the payload) → checks productId and that `transactionId` is not already bound to a different uid (`passes/{transactionId}` = `{ uid }` lookup doc) → writes `users/{uid}.pass` and `passes/{transactionId}`.
- Restore = same call with the current entitlement's JWS.
- Refund/revocation: App Store Server Notifications V2 (`REFUND`, `REVOKE`) → HTTPS function `appStoreNotifications` → deletes `users/{uid}.pass` and `passes/{transactionId}`. Families already created stay (no data loss). The owner enters the function URL in App Store Connect (Sandbox + Production).

## 3. App Store / distribution (owner steps, documented by Backend in TESTFLIGHT.md §H)

- Paid Apps Agreement in App Store Connect (Account Holder; banking + tax forms) — required before any IAP works, even in TestFlight sandbox after a point.
- Create the IAP in App Store Connect (non-consumable, product id above, price, localisation, review screenshot) and submit it with the first app version.
- Public listing: availability = all territories; price of the IAP set once in the base currency and auto-converted by Apple's price tiers. Listing assets per TESTFLIGHT.md §G (screenshots, description, keywords, age rating, App Privacy answers). Provide a demo account that already holds a pass for App Review.
- Privacy page: state that data is stored in Australia (Sydney) and that the app is offered worldwide; keep the existing deletion wording (GDPR/UK/APP: access + deletion via in-app delete and the support email).
- TestFlight: purchases are sandbox (free) — good for testing the flow.
- Apple Small Business Program (15% commission) — owner applies.

## 4. UI (Designer details in DESIGN-SPEC §14)

- **Paywall** appears when the user taps "Create family" without a pass: mascot, "Family Pass", 3 benefit lines, price from StoreKit (`displayPrice`, never hardcoded), primary "Buy Family Pass — {price}", "Restore purchases", "Join with a code instead" (goes to Join). Legal footer: one-time purchase, tied to your Apple ID.
- States: loading products, purchasing (button spinner, UI locked), verifying (after purchase, while the function runs), success ("You're all set" → continues to Create family), pending (Ask to Buy) copy, cancelled (silent), failed (ErrorBanner, §9.1 tone: "Couldn't complete the purchase. Try again."; verification failed: "Couldn't confirm your purchase. Try Restore purchases.").
- **Settings › Family Pass** row: "Active" (with restore) or "Not purchased" → opens paywall; "Restore purchases" always available.
- Family tab: nothing changes for members.
- Copy: no "free trial", no "subscription" words anywhere.

## 5. Constraints

- iOS 16.0 (StoreKit 2 is iOS 15+), Swift 5.9, no force unwraps, `error.userMessage`, English, UTF-16 limits unchanged.
- Never trust the client for entitlement; the server write is the only source of truth. The client may cache the local StoreKit entitlement only to show the paywall faster.
- No secrets in the repo. Apple root certificates (public) are allowed in `firebase/functions/certs/`.
