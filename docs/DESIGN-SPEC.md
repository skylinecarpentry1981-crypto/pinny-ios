# Pinny — Design Spec (iOS 16+, SwiftUI)

Source of truth for every screen the Frontend Dev builds across the 6 build stages (5 build + final Overseer review). Design only — no Swift here.

---

## 0. Brand — Pinny

- **Name:** the app is **Pinny** in every user-facing string (home screen, permission copy, share text, pushes, Settings). The Xcode target, scheme, module, bundle ID and folders stay `FamilyMap` internally; only `CFBundleDisplayName` is `Pinny`. Don't rename code.
- **Mascot:** a white smiling map pin, black outline, pink blush, on teal `#2FC7B5`. App icon: `FamilyMap/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. In-app image asset `PinnyMascot` (transparent PNG, 120 × 144 pt @1x/2x/3x): full size on Welcome (§3.1); 60 × 72 pt in the Family "just you" (§9.3) and Chat (§13.4) empty states. Nowhere else — never on the map, never in SOS.
- **Voice:** friendly and calm, short sentences; never cute in errors or SOS. The mascot is always decorative (hidden from VoiceOver).
- **Colour:** the icon teal drives `brandAccent` and `onAccent` (§5).

---

## 1. Design principles

1. **One primary action per screen.** Everything else is secondary (text link, toolbar icon, or hidden behind a detail view).
2. **Whitespace over boxes.** No card-inside-card. Group with spacing and section headers, not borders.
3. **Typography over decoration.** SF Pro, system semantic colours, no gradients, no custom icons beyond SF Symbols and the Pinny mascot (§0).
4. **Progressive disclosure.** Map first. Chat and Family are one tab away. Settings is behind a gear. Danger (Leave family, Delete account) lives at the bottom of its own screen.
5. **Privacy-first, said out loud.** Location is captured **only when the user opens the app** (or taps Refresh). No background tracking, ever. Every place location is mentioned in copy restates this. See §6.
6. **SOS is unmissable, but never accidental.** Big, red, always on the Map tab; requires a deliberate hold to fire.
7. **Dark mode is free.** Use `Color(.systemBackground)`, `.secondaryLabel`, etc. Only four custom colours exist (§5).

---

## 2. Navigation map

```
Launch
  └─ AuthGate (checks Firebase Auth + users/{uid}.familyId)
       ├─ signed-out ──────────────► Welcome / Sign In
       │                                └─ (success) ► AuthGate re-evaluates
       ├─ signed-in, no familyId ───► Family Onboarding
       │                                ├─ Create family ► Name ► Invite code shown ► Continue ► MainTabView
       │                                └─ Join with code ► Code ► MainTabView
       └─ signed-in + familyId ─────► MainTabView
                                        ├─ [Tab 1] Map (default)
                                        │     ├─ Member Drawer ► tap row / pin ► row expands (Open in Maps · Message · Check in)
                                        │     ├─ Refresh my location / Fit everyone (top-right buttons)
                                        │     └─ SOS button ► SOS Confirm sheet ► "SOS sent"
                                        ├─ [Tab 2] Chat
                                        └─ [Tab 3] Family
                                              ├─ row pin icon ► switch to Map, centre on member, expand their drawer row
                                              ├─ Place row / Add place ► Place editor (full-screen cover, §12.2)
                                              ├─ gear (toolbar) ► Settings (push)
                                              │     ├─ Edit name (inline)
                                              │     ├─ Sign out ► AuthGate ► Welcome
                                              │     └─ Delete account ► Confirm ► Welcome
                                              └─ Leave family ► Confirm ► Family Onboarding

Cross-cutting (shown once, after joining a family and answering the location prompt — §13.1):
  Notification Priming (soft-ask) ► system prompt ► dismiss
```

- **No dead ends:** every terminal (sign-out, delete, leave) routes back through AuthGate.
- **Settings is NOT a tab.** Reached only via the gear on Family tab.
- **SOS confirm = hold-to-confirm (1.5 s).** Chosen over 2-step tap because a hold cannot be triggered by a pocket-tap or a toddler's double-tap, and it works one-handed in a panic.
- **Tab bar:** SF Symbols `map.fill`, `bubble.left.and.bubble.right.fill`, `person.2.fill`. Labels: Map / Chat / Family.

---

## 3. Screens

Legend for states: **L** loading, **E** empty, **X** error, **P** permission-denied.

### 3.1 Welcome / Sign In

```
┌──────────────────────────────┐
│                              │
│        (PinnyMascot)         │  120×144pt, 2 s idle bob
│            Pinny             │  .largeTitle bold
│  Your family, one tap away   │  .title3 secondaryLabel
│  Shares your location only   │  .footnote secondaryLabel
│  when you open the app.      │
│                              │
│                              │
│ [  Sign in with Apple     ]  │  ASAuthorizationAppleIDButton, black, 50pt
│                              │
│      Use email instead       │  .footnote link, secondary
│                              │
│ By continuing you agree to   │  .caption2 tertiaryLabel
│ Terms · Privacy              │
└──────────────────────────────┘
```
- Components: `PinnyMascot`, title `Pinny`, tagline `Your family, one tap away`, privacy line `Shares your location only when you open the app.` (keeps §1.5 on the first screen), `SignInWithAppleButton`, secondary link, legal caption.
- **Mascot:** 120 × 144 pt, centred, decorative. Idle bob: offset y 0 → −6 pt → 0 over 2 s, ease-in-out, repeating; starts on appear, stops when the screen is gone. **Reduce Motion → static.** At accessibility text sizes the mascot drops to 80 × 96 pt so the buttons stay on screen on SE.
- "Use email instead" pushes a minimal Email / Password form with a single **PrimaryButton "Continue"** that both signs in and creates an account (Firebase `signIn` → on `userNotFound` → `createUser`). **Assumption, flag:** email/password kept as a fallback for family members without Apple ID; if product wants Apple-only, drop the link.
- **L:** button shows spinner, disabled. **X:** InfoBanner (red) under the button: "Couldn't sign in. Check your connection and try again."

### 3.2 Family Onboarding

```
┌──────────────────────────────┐
│ Set up your family           │  .largeTitle
│ One family per account.      │  .subheadline secondary
│                              │
│  ┌ Create a family ────────┐ │  inset grouped section
│  │ Family name  [________] │ │
│  │ [ Create family       ] │ │  PrimaryButton
│  └─────────────────────────┘ │
│                              │
│  ┌ Join a family ──────────┐ │
│  │ Invite code [A B C 1 2 3]│ │  6 boxes, monospaced, auto-uppercase
│  │ [ Join family         ] │ │  PrimaryButton (bordered until 6 chars)
│  └─────────────────────────┘ │
│                              │
│                     Sign out │  .footnote, secondary (escape hatch)
└──────────────────────────────┘
```
- Exactly one of the two buttons is "filled" at a time: whichever field has focus/content. The other is `.bordered`.
- **After Create** → replace content with **InviteCodeCard** (big code, Copy, Share) + "Continue to map" PrimaryButton. Copy: "Share this code with your family. They enter it under Join a family."
- **L:** button spinner. **X:** InfoBanner "Couldn't create family" / "Code not found. Check it and try again." Code field shakes on invalid.
- Sign out link at bottom so a stuck user is never trapped.

### 3.3 Map tab

Layout is the Life360-style home: family pill, Member Drawer, floating SOS — wireframes in §11.7 (the Stage 1 wireframe is retired).
- Full-bleed `Map` (`.ignoresSafeArea(edges: .top)`), no nav bar; family-name pill top-centre (§11.1).
- The Apple Maps logo and Legal link must stay visible above the Member Drawer at every snap point (MapKit terms) — see §11.8.
- Pins: `AvatarView(size: .medium)` + 2pt white ring + shadow; **me** gets brand-accent ring. Stale pins (§8) get grey ring at 50 % opacity. First-name label below each pin (§10.4).
- Family Places show as small place annotations beneath all member pins; not tappable (§12.3).
- Tap pin → selects that member and expands their drawer row (§11.4). First load fits fresh pins (≤ 24 h), or all pins if every one is stale (30 % padding, min span 0.01°); after that the camera moves only for **Fit everyone**, a drawer row, a Family-row pin or an SOS card (§10.5).
- **Refresh my location** (SF `location.fill`, top-right): shares one fix now, brief haptic, pin animates; disabled while a share is in flight. The same one-fix share runs automatically when the app becomes active, throttled to once per 2 min. No background tracking (§10.1).
- **Share status:** capsule top-centre, below the family pill: `Sharing…` → `Shared just now` (2 s) → hidden, for auto and manual shares alike. No toast (§10.3).
- **L:** map shows immediately; a small `ProgressView` in the status-capsule slot while the first Firestore snapshot loads. **E (only me):** the drawer shows my row plus an "Invite your family" row with Share (§11.5); my pin still shows. **X:** InfoBanner top: "Can't reach Pinny. Showing last known locations." **P (location denied/restricted):** InfoBanner `.warning` at top (copy §10.2), action Open Settings → `UIApplication.openSettingsURLString`. Map still shows others' pins.

### 3.4 Member Detail — superseded

Replaced in Stage 3.5 by the inline row expansion in the Member Drawer (§11.4). There is no member detail sheet.

### 3.5 Chat tab — superseded

One thread per family. Replaced in Stage 5 by §13.4 (wireframe, grouping, time, input, sending / failed / offline / empty states) and §13.3 (SOS card).

### 3.6 Family tab

```
┌──────────────────────────────┐
│ Family                   ⚙   │  gear → Settings
├──────────────────────────────┤
│ MEMBERS (4)                  │
│ (JK) Jinho Kim (You)      ◎  │  MemberRow, ◎ = mappin.circle
│      Updated just now        │
│ (MA) Mum                  ◎  │
│      Updated 2 h ago         │
│ (SL) Sol · grey ring      ◎  │
│      Last seen yesterday     │
│                              │
│ PLACES (2)                   │  §12.1
│ (⌂) Home             150 m › │  PlaceRow, house.fill
│ (◇) School           300 m › │  graduationcap.fill
│  +  Add place                │
│                              │
│ INVITE CODE                  │
│ ┌──────────────────────────┐ │
│ │  A B C 1 2 3 [Copy][Share] │  InviteCodeCard
│ └──────────────────────────┘ │
│ Anyone with this code can join.
│                              │
│                              │
│      Leave family            │  DestructiveButton (plain, sosRedText)
└──────────────────────────────┘
```
- `List` inset-grouped. Pin icon (`mappin.circle`) is a 44pt tap target → switch to Map tab, centre on that member (zoom 1 km) and expand their drawer row (§11.4). Disabled when the member has no location yet (§10.8). Tapping the row itself does the same; rows without a location aren't tappable.
- Sort: me first, then most-recently-updated.
- **Places** section (between Members and Invite code): rows, Add place, delete, empty state and the 10-place limit — §12.1.
- **Leave family:** confirmation dialog: "Leave this family? You'll need a new invite code to rejoin." [Leave (destructive)] [Cancel]. If the user is the **last member**, copy adds "The family and its chat will be deleted." On success → Family Onboarding.
- **L:** skeleton rows (3 grey capsules). **E:** cannot be empty (I'm always a member). **X:** InfoBanner "Couldn't load family."

### 3.7 Settings (pushed from Family tab)

```
┌──────────────────────────────┐
│ ‹ Family      Settings       │
├──────────────────────────────┤
│ PROFILE                      │
│ (JK)  Display name  Jinho  › │  tap → alert with text field
│       Photo         Add    › │  stage 2 — PhotosPicker
│                              │
│ NOTIFICATIONS                │  rows by permission: §13.2
│ Check-in alerts       [ON ]  │  Toggle = notifyOnCheckIn
│ SOS alerts         Always on │  no toggle
│   SOS alerts can't be turned │  .footnote secondary
│   off — that's the point.    │
│                              │
│ PRIVACY                      │
│ Your location and battery    │  .footnote (exact string §6)
│ level are shared with your…  │
│                              │
│ ACCOUNT                      │
│ Sign out                     │  sosRedText row
│ Delete account               │  sosRedText row
│                              │
│ Pinny 1.0 (12)               │  .caption2 tertiary, centred
└──────────────────────────────┘
```
- Notification rows change with the system permission (allowed / not determined / denied): §13.2.
- **Sign out:** confirmation dialog "Sign out?" [Sign out] [Cancel] → AuthGate.
- **Delete account (Apple 5.1.1(v)):** flow and exact copy in §9.4 (alert → destructive confirm → re-authenticate → Welcome with toast `Your account has been deleted.`). No "type DELETE" field.
- **L:** row spinner on the row being saved. **X:** InfoBanner at top.

### 3.8 SOS Confirm sheet (`.presentationDetents([.medium])`, background `sosRed.opacity(0.08)`)

```
┌──────────────────────────────┐
│ ━━                           │
│                              │
│      Send SOS to family?     │  .title2 bold
│ Everyone gets an alert with  │  .body secondary
│ your current location.       │
│                              │
│   ┌────────────────────────┐ │
│   │ ● Hold to send SOS     │ │  SOSButton, 64pt tall, ring fills over 1.5 s
│   └────────────────────────┘ │
│                              │
│          Cancel              │  .body link
└──────────────────────────────┘
```
- Hold, haptics, early release, the send states (Sharing location → Sending → Sent / Failed), `Call 000` and location-off copy: **§13.3**, which supersedes the Stage 1 success / error / permission notes that were here. Emergency number 000 (AU) stays a constant (Assumption 3).

### 3.9 Notification Priming (soft-ask; shown once — when and re-offer rules: §13.1)

```
┌──────────────────────────────┐
│                              │
│        (bell icon 64pt)      │
│   Stay in the loop           │  .title bold
│   Get a heads-up when a      │  .body secondary
│   family member checks in,   │
│   and always for SOS alerts. │
│                              │
│ [ Turn on notifications ]    │  PrimaryButton → system prompt
│      Not now                 │  .footnote secondary → dismiss for good; re-offer only in Settings (§13.1)
└──────────────────────────────┘
```
- Presented as `.sheet` with `.presentationDetents([.medium])`, swipe-to-dismiss allowed (counts as "Not now").
- **L:** "Turn on notifications" shows spinner while the system prompt is pending, then dismisses on any answer. **E:** not applicable (static content; never shown if permission already granted or denied). **X:** if registration fails after the system prompt, dismiss silently — no banner; the Settings rows (§13.2) surface the state later.

---

## 4. Component inventory

| Component | Size / shape | Behaviour |
|---|---|---|
| **PrimaryButton** | Full-width, 50pt tall, radius 12, `.tint` fill, `.headline` `onAccent` label (set explicitly — iOS draws white, which fails in dark mode, §5); `.bordered` variant | `.disabled` → 40 % opacity. `isLoading` → label replaced by `ProgressView`, width fixed. Haptic `.light` on tap. |
| **DestructiveButton** | Same frame as PrimaryButton; **plain** (`sosRedText` text, no fill) by default; `.filled` (`sosRed` fill, white text) for final confirms only | Never the only visible button; always paired with Cancel. |
| **SOSButton** | 64pt circle floating above the Member Drawer (map, §11.6) / full-width 64pt (sheet); `sosRed` fill, white `.headline` bold "SOS" (sheet adds SF `sos` icon); radius = height/2; shadow y2 blur8 20 % | Map variant: single tap opens sheet. Sheet variant: hold-to-confirm 1.5 s with ring progress + haptics. Scale 0.96 on press. |
| **AvatarView** | `.small` 32pt (rows), `.medium` 40pt (map pins), `.large` 56pt (detail, settings). Circle. | Photo if `photoURL`, else initials (first letter of first + last word, uppercase) on a deterministic hue from `uid.hashValue` (12-colour list, ~60 % sat, ~50 % lum). `ring:` none / accent / grey(stale). |
| **MemberRow** | 64pt tall, AvatarView .small, name `.body`, subtitle `.subheadline` secondary, trailing 44×44 pin button | Family tab only. Whole row tappable (same as the pin button, §3.6); trailing button has its own action + VoiceOver label. |
| **DrawerMemberRow** | 64pt min, AvatarView .medium, name / place / time lines, trailing battery | Map drawer only — spec in §11.4. |
| **PlaceRow** | 52pt min, 32pt icon circle (`brandAccent` 15 %), name `.body`, trailing radius `.subheadline` secondary + chevron | Family tab Places section. Tap → Place editor; swipe → Delete with confirmation — §12.1. |
| **PlaceAnnotation** | 28pt rounded square (radius 8), `brandAccent` 20 % tint, SF Symbol 14pt + `.caption2` name capsule; no shadow | Map tab, beneath all member pins; not tappable in 3.6 — §12.3. |
| **MessageBubble** | Max width 75 %, padding 10×14, radius 18 (2 on the tail corner); incoming `.secondarySystemFill` / `.label`; outgoing `brandAccent` / `onAccent` | Sender name `.caption` above run; time `.caption2` below last of run. Long-press → Copy. |
| **SOSMessageCard** | Full width − 32, radius 12, `sosRed` fill, white text; SF `sos` 24pt leading; `.headline` "{name} sent an SOS · 3:41 pm"; bordered white 44pt "Show on map" | Button → Map tab, select that member (§13.3). Never grouped into a bubble run. |
| **InfoBanner** | Full width, 44pt min, radius 10, padding 12; variants `.info` (secondary fill), `.warning` (orange 15 %), `.error` (`sosRed` 12 %); icon 20pt + `.subheadline` + optional trailing action | Slides in with `.move(edge: .top)`. Whole banner is the tap area when it has an action. |
| **EmptyStateView** | Centred VStack: SF Symbol 48pt secondary (or `PinnyMascot` 60×72pt where §0 says), title `.title3`, message `.body` secondary, optional bordered PrimaryButton | Text max width 280pt. |
| **LoadingView** | Centred `ProgressView` + optional `.footnote` label | Use only when nothing else can render; prefer skeletons in lists. |
| **InviteCodeCard** | Inset grouped card; code in `.title` **monospaced**, 4pt letter-spacing; [Copy] [Share] as 44pt bordered buttons | Copy → `UIPasteboard`, toast "Copied". Share → `ShareLink("Join our family on Pinny with code ABC123")`. |
| **Toast** | Bottom capsule, `.thinMaterial`, `.subheadline`, 2 s | 12pt above the Member Drawer on Map; above tab bar elsewhere. |

---

## 5. Design tokens

**Colours** — semantic first, four custom (brand teal from the Pinny icon, §0).

| Token | Light | Dark | Use |
|---|---|---|---|
| `brandAccent` | `#0A7A6E` (deep teal) | `#2FC7B5` (icon teal) | app tint, text links, my ring, outgoing bubble, toggles |
| `onAccent` | `#FFFFFF` | `#000000` | text and icons on a `brandAccent` fill (PrimaryButton, outgoing bubble, selected chip) |
| `sosRed` | `#D0021B` | `#D0021B` (same in both modes) | **fills only:** SOS button, SOS card background (white text), error banner tint |
| `sosRedText` | `#D0021B` | `#FF453A` | **red text and small red glyphs only:** low-battery %, `Not sent. Tap to retry.`, counter at the limit, destructive text (DestructiveButton plain, Sign out / Delete account rows), failure icons |
| `staleGrey` | `.systemGray3` | auto | stale pin ring |
| background | `.systemBackground` | auto | screens |
| grouped bg | `.systemGroupedBackground` | auto | List screens |
| text | `.label` / `.secondaryLabel` / `.tertiaryLabel` | auto | |
| fills | `.secondarySystemFill` | auto | incoming bubbles, skeletons |

Set `brandAccent` as the app-wide `.tint`. Asset catalog with Any/Dark appearance for the four custom colours:
- `AccentColor.colorset` = `brandAccent`: Any `#0A7A6E` (R 0x0A, G 0x7A, B 0x6E), Dark `#2FC7B5` (R 0x2F, G 0xC7, B 0xB5).
- `OnAccent.colorset` (new): Any `#FFFFFF`, Dark `#000000`. `SOSRed.colorset`: `#D0021B` (R 0xD0, G 0x02, B 0x1B) for Any **and** Dark — replace the old dark `#FF3B30`.
- `SOSRedText.colorset` (new): Any `#D0021B`, Dark `#FF453A` (R 0xFF, G 0x45, B 0x3A).

**Contrast (WCAG 2.1, computed):** `brandAccent` light `#0A7A6E` on white 5.22:1, on `.systemGroupedBackground` `#F2F2F7` 4.68:1, white on it 5.22:1 — AA as text and as a button fill. Dark `#2FC7B5` on black 9.96:1, on `#1C1C1E` (cells, drawer) 8.07:1, on `#2C2C2E` 6.61:1 — AA. White on `#2FC7B5` is only 2.11:1, so fills use `onAccent` (black on it 9.96:1). The brief's `#0B7D71` was rejected: 4.50:1 on `#F2F2F7`, no margin. `#2FC7B5` on white is 2.11:1, so the icon teal is never used in light mode. `sosRed` `#D0021B`: white on it 5.67:1 in both modes, but only 3.71:1 / 3.00:1 as text on black / `#1C1C1E` — hence `sosRedText`: light `#D0021B` 5.67:1 on white, 5.08:1 on `#F2F2F7`; dark `#FF453A` 6.16:1 on black, 4.99:1 on `#1C1C1E` (AA). Keep red text off `#2C2C2E` (4.09:1).

**Type scale (SF Pro, Dynamic Type via text styles — never fixed sizes)**

| Style | Default pt | Weight | Where |
|---|---|---|---|
| `.largeTitle` | 34 | bold | Welcome, Onboarding |
| `.title2` | 22 | bold | SOS sheet |
| `.title3` | 20 | semibold | EmptyState titles |
| `.headline` | 17 | semibold | Button labels, member name in detail |
| `.body` | 17 | regular | Row names, bubbles |
| `.subheadline` | 15 | regular | "Updated x ago", banners |
| `.footnote` | 13 | regular | Privacy note, links |
| `.caption` / `.caption2` | 12 / 11 | regular | Sender names, timestamps, version |

**Spacing:** 4 / 8 / 12 / 16 / 24 / 32. Screen horizontal padding 16 (20 on Welcome). Section gap 24. Element gap inside a group 8.

**Radii:** buttons 12, cards/banners 10–12, bubbles 18, pills = height/2, avatar = circle.

**Shadows:** only on floating things over the map (pins, refresh/fit buttons, SOS button): `y: 2, blur: 8, black 20 %`. The one other shadow is the Member Drawer's top edge (§11.9). Nothing else.

**Haptics:** `.light` on primary taps, `.medium` on pin select, `.success` on SOS sent / code copied, `.error` on failures.

---

## 6. Copy (exact strings)

- **NSLocationWhenInUseUsageDescription**
  `Pinny shares your location with your family only when you open the app or tap Refresh. It never tracks you in the background.`
- **Notification permission (priming screen body; the system alert uses Apple's fixed text)**
  `Get a heads-up when a family member checks in, and always for SOS alerts. You can change this any time in Settings.`
- **Settings › Privacy line**
  `Your location and battery level are shared with your family only when you open Pinny, tap Refresh or Check in, or send an SOS. There is no background tracking. Delete your account at any time to remove your account and location data.`
- **Map share status:** `Sharing…` / `Shared just now` (capsule, no toast — §10.3)
- **Empty family map:** `It's just you for now.` / `Invite your family`
- **App name:** `Pinny` (display name; the Xcode target stays `FamilyMap`, §0).
- **Welcome:** `Pinny` / `Your family, one tap away` / `Shares your location only when you open the app.`
- **SOS push (mandatory, ignores the check-in toggle):** title `🚨 SOS from {name}`; body `Tap to see where they are.` when the SOS carried a location, otherwise `Location unavailable.` (§13.3).
- **Notifications priming, Settings rows, SOS sheet and chat:** exact strings in §13.
- **Check-in push (opt-in per recipient via the Settings `Check-in alerts` toggle, §13.2):** title `{name} checked in`; body `At {placeName}.` when the shared location is inside a Family Place (§12.4 rule, applied on the server), otherwise `Tap to see where they are.` Sent when a member opens the app and shares, or taps Check in — same rule for both; never for an SOS share (`src` `sos`); server-debounced to one per sender per 10 min (§12.5).
- **Family Places:** exact strings in §12.
- **Leave family:** `Leave this family?` / `You'll need a new invite code to rejoin.`
- **Delete account (step 1):** `Delete your account?` / `This deletes your account, name, last location and removes you from your family. Messages you've sent stay in the family chat. This can't be undone.` (§9.4)

en-AU spelling in UI strings (colour, centre). No secrets or config values in copy.

**Character limits** on user input (display name, family name, place name, chat message) are counted in **UTF-16 code units** (`String.utf16.count`), the same unit the Firestore rules check — an emoji counts 2 or more. Input caps, validation and the chat counter all use this count.

---

## 7. Accessibility checklist

- [ ] Every tappable ≥ 44×44pt (pin annotations, refresh circle, row pin button, send, Copy/Share).
- [ ] All text uses Dynamic Type text styles; layouts tested at `.accessibility3` — buttons wrap, never truncate. Bubbles cap at 75 % width but grow vertically.
- [ ] VoiceOver labels: pin → `"{name}, updated {relative}"` (or `"last seen {relative}"` when stale), hint "Double-tap to show in family list". SOS button → label "SOS", hint "Opens confirmation to alert your family". Hold button → label "Hold to send SOS", plus an `accessibilityAction` "Send SOS" so no hold is required with VoiceOver on. Refresh → "Refresh my location". Row pin → "Show {name} on map".
- [ ] New SOS card → `UIAccessibility.post(.announcement, "{name} sent an SOS")` on arrival.
- [ ] Contrast (§5): `brandAccent` 5.22:1 light on white, 8.07:1 dark on `#1C1C1E`; `onAccent` on `brandAccent` 5.22:1 / 9.96:1; white on `sosRed` `#D0021B` 5.67:1 in both modes (fills only); red text uses `sosRedText` — 5.67:1 light on white, 6.16:1 / 4.99:1 dark on black / `#1C1C1E` (§5); `secondaryLabel` only for non-essential text.
- [ ] Reduce Motion: no pin drop animation; hold ring jumps to 100 % at 1.5 s instead of animating.
- [ ] Colour is never the only signal: stale pins get grey ring **and** "Last seen" copy; SOS card has icon **and** text.
- [ ] Map annotations exposed as accessibility elements sorted by name; map labelled "Family map".

---

## 8. Relative time & staleness

`relative(from: updatedAt, now: Date())` — one function, used everywhere.

| Δ | String |
|---|---|
| < 60 s | `Just now` |
| < 60 min | `{n} min ago` |
| < 24 h | `{n} h ago` |
| 24–48 h and calendar-yesterday | `Yesterday` |
| < 7 d | `{n} days ago` |
| ≥ 7 d | `d MMM` (e.g. `3 Sep`); add year if not current year |

Prefix on Map/Family: **"Updated "** when Δ < 24 h, **"Last seen "** when ≥ 24 h. Chat timestamps use no prefix.

**Staleness (≥ 24 h):**
- Pin at 50 % opacity, ring `staleGrey`, drawn **below** fresh pins (z-order).
- Member row (Family tab and drawer) avatar ring grey; time line "Last seen …".
- Excluded from the initial map fit: fit uses fresh pins (≤ 24 h) only; if every pin is stale, fit all (§10.5).
- Never hidden — a stale location is still the best information we have.

Timestamps refresh on a 60 s timer while the view is visible, and on `scenePhase == .active`.

---

## Assumptions (for review)

1. **Auth:** Sign in with Apple primary; email/password secondary fallback. Drop the link if Apple-only is preferred.
2. **SOS confirm:** hold-to-confirm 1.5 s (not 2-step tap).
3. **Emergency number:** `000` (AU) on the SOS-sent state; kept as a constant.
4. **Photo upload** is stage 2; stage 1 ships initials only.
5. **Place line** — reverse-geocoded on the viewer's device for drawer rows, never stored (§11.4). Supersedes Stage 3's no-geocoding rule. `At {placeName}` from Family Places comes first (§12.4).

---

## 9. Stage 2 addendum — auth, family, account deletion

Copy rules: calm, ≤ 60 chars, one sentence, says what to do next. Errors render in the `ErrorBanner` component (`InfoBanner` `.error` style, SF `exclamationmark.circle`) at the **top of the form**, one at a time, never as a system alert or inline text. Map Firebase `AuthErrorCode` / service errors to these strings in one place (`AppError.userMessage`); `error.localizedDescription` must never reach the screen.

### 9.1 Error strings

| Case | Source | String |
|---|---|---|
| Apple sign-in failed (not cancel) | `ASAuthorizationError` ≠ `.canceled`, or Firebase credential error | `Apple sign-in didn't work. Try again.` |
| Wrong password | `.wrongPassword` / `.invalidCredential` | `Wrong password. Try again or reset it.` |
| User not found | `.userNotFound` | `No account with that email. Create one?` |
| Email already in use | `.emailAlreadyInUse` | `That email already has an account. Sign in.` |
| Weak password (< 6) | `.weakPassword` or local check | `Use at least 6 characters.` |
| Invalid email | `.invalidEmail` or local check | `Enter a valid email address.` |
| Network offline | `.networkError` / `URLError.notConnectedToInternet` | `You're offline. Check your connection.` |
| Invite code not found | `FamilyError.codeNotFound` | `Code not found. Check it and try again.` |
| Invite code malformed | `!InviteCode.isValid` (≠ 6 chars, bad char) | `Enter the 6-character code from your family.` |
| Family name empty / too long | local: trimmed empty or > 40 UTF-16 units (§6) | `Give your family a name (1–40 characters).` |
| Requires recent login | `.requiresRecentLogin` | `For your security, sign in again to confirm.` |
| Generic unknown | anything else | `Something went wrong. Try again.` |

Cancelled Apple sign-in shows nothing. "Wrong password" and "User not found" are shown as-is (no enumeration masking) — this is a family app, not a bank.

### 9.2 Email sign-in / create-account

```
┌──────────────────────────────┐
│ ‹ Back      Email            │  inline title
├──────────────────────────────┤
│  [ Sign in ] [Create account]│  segmented Picker, .top 24
│ ┌ ⓘ Wrong password. Try… ──┐ │  ErrorBanner (.error), X state only
│ └──────────────────────────┘ │
│  Name        [__________]    │  create mode only, .textContentType(.name)
│  Email       [__________]    │  .emailAddress, no autocapitalisation
│  Password    [__________]    │  SecureField; create mode: .newPassword
│                              │
│ [ Sign in  /  Create account ]│ PrimaryButton, label follows mode
│                              │
│      Forgot password?        │  .footnote link (sign-in mode only)
└──────────────────────────────┘
```
- Toggle switches title and button label; fields keep their text. Name field animates in (`.transition(.opacity)`).
- Button disabled until: sign-in → email + password non-empty; create → also name trimmed non-empty. Weak/invalid-email checks run locally on tap **before** the network call.
- **L:** `isLoading` spinner in the button, fields disabled, segmented control disabled. **X:** `ErrorBanner` slides in at the top of the form, replacing any previous one; `.error` haptic. On `userNotFound` in sign-in mode the banner is followed by the toggle auto-switching to Create account (fields retained) — one tap to recover.
- "Forgot password?" → `sendPasswordReset`, toast `Reset link sent to {email}`.

### 9.3 Family created — success view (replaces Onboarding content)

```
┌──────────────────────────────┐
│       ✓ Family created       │  .title2 bold, brandAccent check
│   Share this code with your  │  .body secondary, max 280pt
│  family. They enter it under │
│        Join a family.        │
│                              │
│         A B C 1 2 3          │  .largeTitle monospaced bold, 6pt letter-spacing
│    [ Copy ]    [ Share ]     │  44pt bordered, side by side
│                              │
│ [ Continue to map          ] │  PrimaryButton
└──────────────────────────────┘
```
- Copy → `UIPasteboard`, toast `Copied`, `.success` haptic. Share → `ShareLink(item:)` with exact text: **`Join our family on Pinny with code ABC123`** (code substituted, no trailing punctuation, no URL until a store link exists).
- Continue → MainTabView. Back-swipe disabled (family already exists; there is nothing to go back to).
- **Family tab, only me (E):** Members section shows my row only; below the invite card an `EmptyStateView`: `PinnyMascot` 60 × 72 pt (§0), title `It's just you for now`, message `Share the code above and your family will appear here.` No button (Share is already on screen).

### 9.4 Delete account (Apple 5.1.1(v))

**Decision:** chat messages you sent stay in the family chat with the `senderName` snapshot already stored on each message (`ChatMessage.senderName`) — deleting a user must not tear holes in other people's conversation. Step 1 says this plainly.

1. **Alert** — title `Delete your account?` / message `This deletes your account, name, last location and removes you from your family. Messages you've sent stay in the family chat. This can't be undone.` Buttons: [Cancel] [Continue] (destructive).
2. **Destructive confirm** (pushed, full screen) — title `Delete my account`; body repeats the list as four bullets (Account · Name · Last location · Family membership); `DestructiveButton(.filled)` **`Delete my account`** + plain `Cancel`. No "type DELETE" field (§3.7 superseded).
3. **Re-authenticate** — depends on the sign-in provider:
   - **Apple: always shown.** Tapping `Delete my account` in step 2 opens this step every time, because we need a fresh Apple authorisation code to revoke the Apple token (Apple requires it). InfoBanner `.info`: `Sign in with Apple to confirm.` with the message `Apple needs to confirm before we delete your account.` Below it is `SignInWithAppleButton(.continue)` plus a plain `Cancel`. On success: reauthenticate, revoke the Apple token, then delete, with no extra tap. If the user cancels the Apple sheet, stay on this step with no error.
   - **Email: only if Firebase asks.** Try the delete first. If Firebase throws `requiresRecentLogin`, open a `.sheet` with InfoBanner `.info` `For your security, sign in again to confirm.`, a `Password` SecureField, and PrimaryButton `Confirm and delete`. On success: reauthenticate, then delete. A wrong password shows the §9.1 string in the sheet's `ErrorBanner`. If Firebase doesn't ask, go straight to step 4.
4. **End state** — AuthGate routes to Welcome; toast (3 s) `Your account has been deleted.` No further dialogs.

**L:** step 2 button spinner, Cancel disabled. **X:** `ErrorBanner` at top of step 2 with the mapped string; button re-enabled.

### 9.5 Leave family

Confirmation dialog: title `Leave this family?` / message `You'll need a new invite code to rejoin.` [Leave] (destructive) [Cancel]. Last member: message becomes `You're the last member. The family and its chat will be deleted.`
Result: `users/{uid}.familyId` cleared → AuthGate → **Family Onboarding** (empty fields, no error). If the **creator** leaves, the family continues; the server promotes the longest-standing remaining member to creator — nothing changes in the UI, no one is told.

### 9.6 Sign out

Confirmation dialog: title `Sign out?` / message `Your family and messages stay. Sign back in any time.` [Sign out] (destructive) [Cancel] → AuthGate → Welcome. No toast.

### 9.7 Accessibility — invite code

- Code `Text` gets `.accessibilityLabel("Invite code, A, B, C, 1, 2, 3")` — characters joined by ", " so VoiceOver reads them one at a time instead of trying to pronounce "ABC123" as a word. Same on the 6-box entry field (label per box: `Character 3 of 6`).
- Copy button label `Copy invite code`, Share label `Share invite code`; toast `Copied` is also posted as a `.announcement`.
- Letter-spacing is visual only — never insert real spaces into the stored code. `InviteCode.normalize` strips whitespace on entry, so pasted spaced codes still match.
- Code contrast: `.label` on grouped background; no colour-only meaning. Dynamic Type: `.largeTitle` scales; at `.accessibility3` the Copy/Share buttons stack vertically.

---

## 10. Stage 3 addendum — location sharing and map

Behaviours and strings below are fixed by the orchestrator; Frontend builds to them. §2, §3.3, §3.4, §3.6, §6, §8 and Assumption 5 were edited to match, so there is one truth. Stage 3.5 (§11) supersedes §10.6, §10.7 and §10.9 and adjusts §10.1, §10.3, §10.5, §10.8 and §10.10.

### 10.1 When we share
- **Auto:** app becomes active (`scenePhase == .active`) + signed in + has a family → request **one** location fix and share it once. Throttled: skip if the last auto-share was < 2 min ago.
- **Manual:** Refresh button, top-right, SF `location.fill`, 44 pt circle `.thinMaterial` → one fix, shared now (not throttled). Disabled (40 % opacity) while any share is in flight. Label `Refresh my location`. `Check in` on my drawer row (§11.4) does the same.
- **Never:** background updates, significant-change, region monitoring, or a continuous stream. Leaving the foreground sends nothing more.
- Fix timeout 15 s.
- Every share — auto on open or manual Refresh / Check in — can trigger the check-in push to family (§6): opt-in per recipient, server-debounced 10 min per sender. Each share also stores `acc` (horizontal accuracy, metres).

### 10.2 Permission
| State | UI |
|---|---|
| Not determined | System prompt on the first share attempt (usage string §6). |
| Denied / restricted | InfoBanner `.warning`, SF `location.slash`: title `Location is off`, body `Turn it on to share where you are with your family.`, action `Open Settings` → `UIApplication.openSettingsURLString`. No share attempted. Others' pins still show. |
| Authorised, Precise off | Accepted silently — share the approximate fix with its `acc`; drawer rows then show the suburb only (§11.4). No banner, no nudge to turn Precise on. |

Prompt order: on first launch after joining, the location system prompt comes first; Notification Priming (§3.9) waits until it is answered, so two permission asks never stack.

### 10.3 Status and errors
- **Status capsule** (top-centre below the family pill, §11.1; `.thinMaterial`, `.footnote`, 32 pt tall, 1 line): `Sharing…` with a small leading `ProgressView` while in flight → `Shared just now` with SF `checkmark` for 2 s after success → hidden. Shown for auto **and** manual shares — each share is visible (§1.5).
- **Failure** (no fix within 15 s, or a location error): ErrorBanner `Couldn't get your location. Try again.`
- **Offline:** ErrorBanner `You're offline. Check your connection.` (same string as §9.1). Check reachability before writing — Firestore queues offline writes, so without the check this case would only surface as a timeout.
- **Late commit (known, accepted):** if a share's write commits after its 10 s timeout, the UI may already have shown the offline message even though the share landed. The next successful share corrects it (capsule and time line update); no extra handling.
- Error banners replace the capsule for that attempt; they hide on the next successful share or on tap. Refresh is the retry. `.error` haptic on manual attempts only.
- VoiceOver: result string posted as `.announcement` after a **manual** refresh only; auto shares stay silent.

### 10.4 Pins
- `AvatarView` 40 pt + 2 pt white ring + shadow (§5). **Me:** `brandAccent` ring. **Stale (> 24 h):** 50 % opacity, `staleGrey` ring, drawn below fresh pins.
- Label below: first name (first word of display name), `.caption` semibold on a `.thinMaterial` capsule so it reads over any tile; 1 line, tail-truncate at 80 pt. Pin + label is one tap target (≥ 44 pt).
- VoiceOver: `Mum, updated 12 min ago`; stale `Mum, last seen 3 days ago`; me `You, updated just now`. Hint `Double-tap to show in family list`. Selected pin (§11.4) scales 1.2 and draws on top.

### 10.5 Region
- First snapshot with ≥ 1 located member: fit **fresh** members (updated ≤ 24 h); if every located member is stale, fit all of them. 30 % padding inside the visible map area (top stack → drawer top edge, §11.8), min span 0.01° (≈ 1 km). One member → centred at min span.
- Later snapshots and my own shares **never** move the camera.
- **Fit everyone** button: SF `person.2.circle`, same 44 pt circle, 8 pt under Refresh → re-runs the first-load fit. Disabled when no one has a location. Label `Fit everyone`.
- Pan + zoom only (no rotate), so no system compass competes with the top-right buttons.

### 10.6 Member Detail — superseded
Replaced by the drawer row expansion (§11.4). Stage 3's no-reverse-geocoding rule is superseded too: place lines are geocoded on the viewer's device and never stored.

### 10.7 Members without a location — superseded
No capsule: they appear as greyed rows at the bottom of the Member Drawer (§11.4). The only-me card is replaced by the drawer's Invite row (§11.5).

### 10.8 Family tab → Map
Trailing `mappin.circle` on each MemberRow (44 pt) → switch to Map tab, centre on that member (1 km span), select and expand their drawer row (drawer goes to half if collapsed). Disabled (40 % opacity, VoiceOver "dimmed") when the member has no location. Label `Show {name} on map`.

### 10.9 Map tab layout — superseded
See §11.7 (wireframes) and §11.8 (z-order and safe areas).

### 10.10 Privacy in the UI
- The Settings › Privacy line is the exact §6 string (updated in Stage 3.5 to cover battery, Check in and SOS).
- **No location history UI exists, by design:** one latest location per member, overwritten on each share. No trails, timelines or visit lists; adding one needs a privacy review first. Family Places (§12, owner-approved in Stage 3.6) only label the latest location; no visits or entries are recorded.
- The status capsule is the visible receipt of every share — sharing is never silent.
- Drawer place lines are geocoded on the viewer's device and never stored (§11.4). Apple Maps receives a coordinate only when the viewer taps Open in Maps. Battery sharing: §11.11.
- To stop sharing: turn off location for Pinny in iOS Settings, leave the family, or delete the account (§9.4). No in-app pause this stage.

---

## 11. Life360-style home (Stage 3.5)

Owner direction: Life360 as the visual reference. Hard constraint unchanged — location is shared **only** on app open, manual refresh / Check in, and SOS; no background tracking, no history. Out of scope pending an owner decision: history, driving, crash detection, and background place alerts (Stage 3.6 adds app-open place labels only — §12). This section supersedes §3.4, §10.6, §10.7 and §10.9.

### 11.1 Top of the Map tab
Full-bleed map, no nav bar. Top stack pinned to safe-area top + 8:
- **Row A (44 pt):** family pill centred — the family name as stored (e.g. `Kim family`), `.subheadline` semibold on a 36 pt `.thinMaterial` capsule, tail-truncated. Non-interactive (one family per account); VoiceOver header trait. **Refresh** trailing 16.
- **Row B (44 pt, 8 below):** status capsule centred (§10.3); **Fit everyone** trailing, under Refresh.
- **Row C (8 below, optional):** one banner (§10.2 / §10.3), full width − 32.
- Pill and capsule max width = screen − 2 × (16 + 44 + 8) = 239 pt on SE. Settings stays on the Family tab — no gear here.

### 11.2 Member Drawer
A custom in-view panel inside the Map tab, resting on the tab bar — **not** a system `.sheet` (iOS 16.0 has no `presentationBackgroundInteraction`, and a sheet would cover the tab bar). The map stays pannable above it.

| Snap | Height | SE 375×667 | iPhone 15 393×852 |
|---|---|---|---|
| Collapsed | 128 pt = handle zone 20 + header 44 + one row 64 | top y 490 | top y 641 |
| Half | 45 % of (safe-area top → tab-bar top) | 269 pt, top y 349 | 320 pt, top y 449 |
| Full | top edge at safe-area top + 56 — pill row stays on the map | top y 76 | top y 115 |

- Opens at **half** on launch; keeps the last snap while the app runs. **Tap handle:** cycles collapsed → half → full → collapsed.
- **Drag** (handle, header, or anywhere when collapsed): follows the finger; on release snaps to the nearest point, or the next one in the flick direction above 500 pt/s. Spring (response 0.35, damping 0.85); Reduce Motion → 0.2 s ease, no bounce.
- The list scrolls in half and full. In full, pulling down with the list at its top drags the drawer; if that hand-off is flaky on iOS 16, handle + header alone are the drag zone.
- **Header (44 pt):** `{n} people` (`Just you` when alone), `.subheadline` semibold secondary. In **full**, rows B–C are hidden: the header shows the status text in place of the count while a share runs, a small red `SOS` capsule (44 pt tall) trailing, and an active banner becomes the first list item.

### 11.3 SOS on the home screen
- 64 pt `sosRed` circle, white `SOS` `.headline` bold, shadow per §5. Trailing 16; bottom 12 pt above the drawer's top edge; moves with the drawer in collapsed and half.
- Dragging past half toward full, it fades out over the last 40 pt; in full the header `SOS` takes over, so SOS is always one tap away. It also hides (header SOS shows) whenever it would overlap the top stack — large text plus a banner.
- Tap → SOS Confirm sheet (§3.8); hold-to-confirm 1.5 s unchanged.

### 11.4 Drawer member row (`DrawerMemberRow`)
Avatar `.medium` 40 pt leading (rings per §10.4) · three text lines · battery trailing. 64 pt min, grows with Dynamic Type; 16 pt side padding; separators inset 72.
- **Name** `.body` semibold — `You` for me.
- **Place** `.footnote` secondary, 1 line: inside a Family Place (within `radius`, `acc` ≤ `radius`) → `At Home` (§12.4; first priority, and that row skips geocoding); otherwise `Near 12 George St, Parramatta`; no number → `Near George St, Parramatta`; `acc` > 500 m or no street found → `Near {locality}` (e.g. `Near Parramatta`). Geocoding pending / failed / offline → `Location shared`. No location → `No location yet`. `CLGeocoder` on the viewer's device, cached in memory per coordinate (4 dp), one request at a time and only when a coordinate changes (Apple rate-limits it). **Never written to Firestore.**
- **Time** `.caption` secondary: `Updated 12 min ago` / `Last seen yesterday` (§8); hidden when no location.
- **Battery:** SF `battery.100` (88–100) / `.75` (63–87) / `.50` (38–62) / `.25` (13–37) / `.0` (0–12) + `{n}%` `.caption` monospaced digits. Charging → `battery.100.bolt`. ≤ 15 % → symbol and text `sosRedText`. Hidden when unknown.
- **Sort:** You → others by latest `updatedAt` (stale fall below fresh) → members without a location.
- **Tap row or its map pin** → select (one at a time): map centres the member at span 0.01° inside the visible map area; the row expands inline (+52 pt) with 44 pt bordered buttons. A pin tap also lifts a collapsed drawer to half and scrolls the row into view. Deselect by tapping the selected row (or its pin) again. Tapping empty map does **not** deselect — a tap gesture on the iOS 16 SwiftUI `Map` conflicts with panning and pin taps.

| Row | Expanded actions |
|---|---|
| Other member, located | `Open in Maps` (Apple Maps at the coordinate, labelled with the name) · `Message` (→ Chat tab) |
| Me | `Check in` = manual share (§10.1); disabled while sharing. Same check-in push rule as an app-open share (§6) |
| No location | Greyed (avatar + text `.tertiaryLabel`, 50 %); `Message` only, full strength; no map move |

### 11.5 Only-me family
My row, then an **Invite row**: SF `person.badge.plus` in a 40 pt `.secondarySystemFill` circle, title `Invite your family`, subtitle `It's just you for now.`, trailing bordered `Share` (44 pt) → `ShareLink` with the §9.3 text. Header reads `Just you`. Replaces the Stage 1 map card.

### 11.6 What the drawer replaces
§3.4 Member Detail sheet → row expansion. §10.7 `No location yet` capsule → greyed rows. Only-me map card → Invite row. Pin tap and Family-tab pin (§10.8) → select + expand the row.

### 11.7 Wireframes (Mum selected in Half; ▯12% = red, ≤ 15 %)

1 line ≈ 32 pt. SE = 375 × 667 pt, 15 = iPhone 15, 393 × 852 pt.
```
SE · Collapsed 128 pt         SE · Half 269 pt              SE · Full, top y 76
┌─────────────────────────┐   ┌─────────────────────────┐   ┌─────────────────────────┐
│ 9:41                    │   │ 9:41                    │   │ 9:41                    │
│     ( Kim family )  [⟳] │   │     ( Kim family )  [⟳] │   │     ( Kim family )  [⟳] │
│      ( Sharing… )   [⤢] │   │      ( Sharing… )   [⤢] │   │╭──────────━━━──────────╮│
│                         │   │      (JK)       (M)     │   │ 4 people         [SOS]  │
│      (JK)       (M)     │   │      Jinho      Mum     │   │ (JK) You          ▮80%  │
│      Jinho      Mum     │   │   (J)                   │   │      Near 3 Church St…  │
│   (J)                   │   │   Jiwoo  · stale        │   │ (M)  Mum          ▯12%  │
│   Jiwoo  · stale        │   │                         │   │      Near 12 George St… │
│                         │   │                         │   │ (J)  Jiwoo        ▮55%  │
│                         │   │                   (SOS) │   │      Last seen yesterday│
│                         │   │                         │   │ (D)  Dad  · greyed      │
│                         │   │╭──────────━━━──────────╮│   │      No location yet    │
│                         │   │ 4 people                │   │                         │
│                   (SOS) │   │ (JK) You          ▮80%  │   │                         │
│                         │   │      Near 3 Church St…  │   │                         │
│╭──────────━━━──────────╮│   │ (M)  Mum          ▯12%  │   │                         │
│ 4 people                │   │      Near 12 George St… │   │                         │
│ (JK) You          ▮80%  │   │ [Open in Maps] [Message]│   │                         │
│      Near 3 Church St…  │   │ (J)  Jiwoo        ▮55%  │   │                         │
├─────────────────────────┤   ├─────────────────────────┤   ├─────────────────────────┤
│ Map     Chat    Family  │   │ Map     Chat    Family  │   │ Map     Chat    Family  │
└─────────────────────────┘   └─────────────────────────┘   └─────────────────────────┘

15 · Collapsed 128 pt          15 · Half 320 pt               15 · Full, top y 115
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
│ 9:41                     │   │ 9:41                     │   │ 9:41                     │
│                          │   │                          │   │                          │
│      ( Kim family )  [⟳] │   │      ( Kim family )  [⟳] │   │      ( Kim family )  [⟳] │
│       ( Sharing… )   [⤢] │   │       ( Sharing… )   [⤢] │   │╭──────────━━━───────────╮│
│                          │   │      (JK)       (M)      │   │ 4 people          [SOS]  │
│      (JK)       (M)      │   │      Jinho      Mum      │   │ (JK) You           ▮80%  │
│      Jinho      Mum      │   │   (J)                    │   │      Near 3 Church St…   │
│   (J)                    │   │   Jiwoo  · stale         │   │ (M)  Mum           ▯12%  │
│   Jiwoo  · stale         │   │                          │   │      Near 12 George St…  │
│                          │   │                          │   │ (J)  Jiwoo         ▮55%  │
│                          │   │                          │   │      Last seen yesterday │
│                          │   │                          │   │ (D)  Dad  · greyed       │
│                          │   │                    (SOS) │   │      No location yet     │
│                          │   │                          │   │                          │
│                          │   │╭──────────━━━───────────╮│   │                          │
│                          │   │ 4 people                 │   │                          │
│                          │   │ (JK) You           ▮80%  │   │                          │
│                          │   │      Near 3 Church St…   │   │                          │
│                    (SOS) │   │ (M)  Mum           ▯12%  │   │                          │
│                          │   │      Near 12 George St…  │   │                          │
│╭──────────━━━───────────╮│   │ [Open in Maps] [Message] │   │                          │
│ 4 people                 │   │ (J)  Jiwoo         ▮55%  │   │                          │
│ (JK) You           ▮80%  │   │      Last seen yesterday │   │                          │
│      Near 3 Church St…   │   │ (D)  Dad  · greyed       │   │                          │
├──────────────────────────┤   ├──────────────────────────┤   ├──────────────────────────┤
│ Map     Chat    Family   │   │ Map     Chat    Family   │   │ Map     Chat    Family   │
└──────────────────────────┘   └──────────────────────────┘   └──────────────────────────┘
```

### 11.8 Z-order and safe areas
- Back → front: map → place annotations (§12.3) → stale pins → fresh pins → selected pin → drawer → SOS → top stack → banner → system sheets (SOS Confirm).
- Drawer bottom = tab-bar top; the tab bar keeps its standard material. Fit and centring use the visible map between the top stack and the drawer's top edge. Inset the map's bottom by the current drawer height so MapKit keeps its Apple logo and Legal link visible just above the drawer — Frontend to confirm on an iOS 16 device.
- SE half at default text: top stack with banner ends ≈ y 210, SOS starts y 273 — clear. Map toasts: centred, 12 pt above the drawer, max width screen − 2 × 88 so they never meet SOS.

### 11.9 Tokens
Drawer: top corners radius 20; `.regularMaterial` (`.systemBackground` when Reduce Transparency is on); top-edge shadow `y: −2, blur: 12, black 12 %` — the one shadow outside the floating controls (§5). Handle 36 × 5 capsule, `.tertiaryLabel`, 44 pt tap area. Row 64 pt min (+52 expanded). SOS 64 pt circle; header SOS 44 pt capsule.

### 11.10 Accessibility
- Handle: label `Family list`, value `Collapsed` / `Half` / `Full`, adjustable — increment expands, decrement collapses. Snap changes post `.layoutChanged`.
- Row = one element: `Mum, near George St Parramatta, updated 12 min ago, battery 40 percent` (street + suburb, no number or comma; `, charging` appended when charging). Inside a place: `Mum, at Home, updated 12 min ago, battery 40 percent` (§12.4). Me `You, …`; no location `Dad, no location yet`. Hint `Double-tap to show on map`. Expanded actions are separate buttons and also custom actions on the row.
- Reading order: family pill, status, Refresh, Fit, banner, map, SOS, handle, rows. Battery % is always text, so red is never the only signal. At accessibility sizes the place line wraps to 2 lines; battery stays on the name line.

### 11.11 Privacy — battery and addresses
- **Battery is new shared data:** level 0–100 (integer) + charging (bool), captured only at share time (app open, Refresh / Check in, SOS) and written with the location and its `acc` (metres). Shown only to family; nothing is sampled in between, so it can be old — the time line says how old. Removed with the account (§9.4).
- **Addresses are never stored:** geocoded per viewer, on device, held in memory only. Apple's geocoder sees the coordinate; Firestore never sees an address.
- Still no history, trails, driving or crash features (§10.10) — each needs an owner decision and most would break the no-background rule. Family Places (§12) only label a shared location; nothing is monitored.

---

## 12. Family Places (Stage 3.6)

Fixed by the orchestrator in `docs/STAGE-3.6-CONTRACT.md`; this section is the UI detail. App-open-only is unchanged: places only **label** a location that was already shared (app open, Refresh, Check in, SOS). Nothing is monitored, no new permission, no extra battery. §2, §3.3, §3.6, §4, §6, §10.10, §11, §11.4, §11.8, §11.10, §11.11 and Assumption 5 were edited to match.

### 12.1 Family tab → Places section
Between MEMBERS and INVITE CODE (§3.6). Header `PLACES ({n})`, or `PLACES` when there are none.
- **PlaceRow** (52 pt min, grows with Dynamic Type): 32 pt circle, `brandAccent` 15 % fill, SF Symbol in `brandAccent` by `icon` — `home` → `house.fill`, `school` → `graduationcap.fill`, `work` → `briefcase.fill`, `pin` → `mappin` · name `.body`, 1 line, tail-truncated · trailing radius `150 m` (`{n} m`, non-breaking space) `.subheadline` secondary · disclosure chevron. **Tap** → Place editor, edit mode (§12.2); any member can edit any place.
- **Add place** row: SF `plus.circle.fill` in the icon slot, label `Add place`, both `brandAccent` → Place editor, new mode. At 10 places the row is hidden and the section footer reads `Up to 10 places.` (`.footnote` secondary); under 10 there is no footer.
- **Empty (0 places):** one non-tappable row, `.subheadline` secondary, wraps: `Add places like Home or School to see who's there.` The Add place row follows it.
- **Swipe to delete:** trailing `Delete` (destructive, no full swipe) → confirmation dialog, title `Delete {name}?`, message `It's removed for everyone in your family.` [Delete] (destructive) [Cancel]. Reachability is checked before the write (§10.3). **X:** ErrorBanner at the top of the list `Couldn't delete the place. Try again.`; offline → `You're offline. Check your connection.` (§9.1).
- Sort by `createdAt`, oldest first. Duplicate names are allowed (two children, two schools).
- **L:** one skeleton row until the first `places` snapshot arrives.

### 12.2 Place editor
**Presentation: `.fullScreenCover` with its own `NavigationStack`** — not a push, not a `.sheet`. Save / Cancel is a self-contained modal task (HIG). A push adds an edge back-swipe that fights map panning and keeps the tab bar on iOS 16; a sheet can be pulled down mid-pan and costs the SE ~50 pt of map. A cover has no dismiss gesture, so Cancel is the only exit and the discard check always runs.
Nav bar inline: `Cancel` leading · title `New place` / `Edit place` · `Save` trailing (`.bold`).
```
SE · 375 × 667                15 · 393 × 852
┌─────────────────────────┐   ┌──────────────────────────┐
│ 9:41                    │   │ 9:41                     │
│ Cancel  New place  Save │   │                          │
│ [⌕ Search for an addr…] │   │ Cancel  New place   Save │
├─────────────────────────┤   │ [⌕ Search for an addre…] │
│                         │   ├──────────────────────────┤
│                         │   │                          │
│         ╭─────╮         │   │                          │
│       ╭─╯     ╰─╮       │   │                          │
│       │    ▼    │       │   │                          │
│       ╰─╮  ·  ╭─╯       │   │         ╭─────╮          │
│         ╰─────╯         │   │       ╭─╯     ╰─╮        │
│                         │   │       │    ▼    │        │
│                     [➤] │   │       ╰─╮  ·  ╭─╯        │
├─────────────────────────┤   │         ╰─────╯          │
│ Radius            150 m │   │                          │
│ 100 ─●───────────── 500 │   │                          │
│ [ Home                ] │   │                          │
│ [Home] (School) (Work)  │   │                      [➤] │
│                         │   ├──────────────────────────┤
└─────────────────────────┘   │ Radius             150 m │
                              │ 100 ─●────────────── 500 │
                              │ [ Home                 ] │
                              │ [Home] (School) (Work)   │
                              │                          │
                              │                          │
                              └──────────────────────────┘
```
Legend: ▼ fixed centre pin (its tip is the saved coordinate) · ╭╮ radius circle · [➤] Use my location · [Home] selected chip.
- **Map:** sits between the search field and the bottom panel, never under them, so its region centre is the visual centre and the saved `lat` / `lng`. Pan and zoom only. Opens on the place (edit), else on my last shared location, else on the Map tab's current centre — no new fix on open. First zoom makes the circle 60 % of the map width.
- **Centre pin:** SF `mappin` 32 pt `brandAccent`, tip on the centre, 6 pt dot under it; not interactive.
- **Radius circle:** drawn in screen space over the map (the iOS 16 SwiftUI `Map` has no overlays): diameter = 2 × radius ÷ metres per point at the current region, recomputed on every region change. `brandAccent` 15 % fill, 2 pt `brandAccent` stroke, clipped to the map, no hit testing. On slider release, if the circle is wider than the map's short side, zoom out until it is 80 % of it.
- **Search:** rounded field under the nav bar, SF `magnifyingglass`, placeholder `Search for an address`, clear button. `MKLocalSearch` runs on Return (not per keystroke), biased to the visible region. Results slide down over the map (`.regularMaterial`, max 50 % of the map height, scrolls): name `.body` + address `.footnote` secondary, 44 pt min rows. Tap → centre the map there (zoom kept), close the list and keyboard, keep the query; the name is not changed. Empty query → no list. Searching → small `ProgressView` in the field. No results → one row `No results. Try a street or suburb.` Offline → ErrorBanner `You're offline. Check your connection.`; other failure → `Search didn't work. Try again.`
- **Use my location** (SF `location.fill`, 44 pt `.thinMaterial` circle, bottom-trailing on the map, 12 inset): one fix (15 s timeout, §10.1) that recentres the map; spinner while pending. The fix stays on the device — it is not a share: no Firestore write, no status capsule, no push. Not determined → system prompt (§6 string). Denied / restricted → InfoBanner `.warning` `Location is off` / `Search for an address, or turn it on in Settings.`, action `Open Settings`; the button stays enabled so a tap always explains itself. Failure → `Couldn't get your location. Try again.` (§10.3).
- **Radius:** `Radius` `.subheadline` + live value `150 m` trailing (monospaced digits). `Slider` 100–500, step 50, default 150, end labels `100` / `500` `.caption2`; `.selection` haptic per step; the circle follows live.
- **Name:** `TextField`, placeholder `Name`, word capitalisation, input stops at 30 UTF-16 units (an emoji counts 2+, §6). Chips below — `Home` (`house.fill`) · `School` (`graduationcap.fill`) · `Work` (`briefcase.fill`): 44 pt bordered capsules; selected = `brandAccent` fill, `onAccent` text. A chip tap sets the name. The icon follows the name: trimmed name equals a preset (any case) → that icon, chip selected; anything else → `pin`, no chip selected.
- **Save** is disabled while the name field is empty, while saving, and (edit mode) until something changes. On tap, local checks run first: trimmed name 1–30 UTF-16 units, else ErrorBanner `Give the place a name (1–30 characters).`, `.error` haptic, name field focused; (new) family already has 10 → `Your family has 10 places. Delete one first.` **L:** Save becomes a `ProgressView`; Cancel, fields and map disabled. **Done:** dismiss, `.success` haptic, no toast — the row appears. **X:** `Couldn't save the place. Try again.`; offline (checked first, §10.3) → `You're offline. Check your connection.`; a 10 s timeout counts as failure; Save re-enables.
- **Cancel:** nothing changed → dismiss. Centre, radius or name changed → confirmation dialog `Discard changes?` [Discard] (destructive) [Keep editing].
- **Banners:** one at a time, directly under the search field (§9 "top of the form"); hidden on tap or on the next success. Tone per §9: calm, ≤ 60 chars, says what to do next.
- **Keyboard:** search focused → bottom panel hides; name focused → the panel rides above the keyboard, the map shrinks, centre kept.

### 12.3 Map tab place annotations
- **PlaceAnnotation:** 28 pt rounded square (radius 8), `brandAccent` 20 % over `.regularMaterial`, 1 pt white stroke, SF Symbol 14 pt semibold `brandAccent` (mapping §12.1). No shadow — it sits on the ground, it does not float (§5). Name below, `.caption2` secondary on a `.thinMaterial` capsule, 1 line, tail-truncated at 80 pt.
- Drawn beneath every member pin (z-order §11.8). In the iOS 16 SwiftUI `Map` that means one `annotationItems` array (place / member enum) with places first — Frontend to confirm on device, as for stale pins.
- Not tappable in 3.6: no hit testing, so taps reach pins underneath. No radius circle on the Map tab. Places are left out of the first-load fit and Fit everyone (§10.5).
- VoiceOver: label `Place, Home`; static text, no button trait, no hint; ordered after members.

### 12.4 Drawer row place line
Computed on the viewer's device, never stored: inside when the distance from `lastLocation` to the place centre is ≤ `radius` **and** `acc` ≤ `radius` (`acc` missing on legacy docs → allowed); several matches → nearest centre wins. Recomputed when `places` or a member's location changes.
- Priority, first that applies: `At {placeName}` > `Near {street}, {suburb}` > `Near {suburb}` > `Location shared` > `No location yet`. Example `At Home`. Style unchanged (§11.4): `.footnote` secondary, 1 line, tail-truncated.
- When `At` applies, that row skips `CLGeocoder` (fewer requests against Apple's rate limit).
- VoiceOver: `Mum, at Home, updated 12 min ago, battery 40 percent`.

### 12.5 Check-in push (resolves the Overseer carry-forward; §6 updated to match)
- Title `{name} checked in`. Body `At {placeName}.` when the shared location is inside a place (the server applies the §12.4 rule to the family's `places`), otherwise `Tap to see where they are.`
- Sent only when `src` is `open`, `manual` or absent (legacy); never for `sos`. The 10-min per-sender debounce and the `notifyOnCheckIn` opt-in are unchanged.

### 12.6 Accessibility
- Radius slider: label `Radius`, value spoken `150 metres` (never "150 m"), adjustable — swipe up / down moves 50 m.
- Every tappable ≥ 44 × 44 pt: PlaceRow, Add place, chips, search clear, result rows, Use my location, Cancel, Save.
- PlaceRow is one element: `Home, radius 150 metres`, hint `Double-tap to edit`; Delete is a custom action (swipe actions are exposed automatically). The empty-state row is static text.
- Editor Dynamic Type: text styles only. At accessibility sizes the bottom panel becomes a `ScrollView` capped at 50 % of the screen, so the map keeps half; the radius value moves above the slider and chips wrap to a second line. Only the nav title may truncate.
- Editor map: label `Place map`, value `Circle radius 150 metres`. Panning is hard with VoiceOver, so search and Use my location are the accessible ways to set the centre; pin and circle are hidden from VoiceOver. Order: Cancel, title, Save, search, banner, results, map, Use my location, radius, name, chips.
- Reduce Motion: no animated recentre or zoom; the results list appears without sliding.

### 12.7 Privacy
- A place (name, centre, radius) is family data, visible to the family only. Matching runs on each viewer's device; the server matches only to write the push body. No visits, entries or history are recorded.
- Search text goes to Apple (`MKLocalSearch`), like the geocoder (§11.11); Firestore receives only the saved place.

---

## 13. Stage 4 & 5 addendum — notifications, SOS, chat

Resolves what §3.5, §3.8 and §3.9 left open; those sections now point here, and §2, §3.7, §4, §6 and §7 were edited to match. Pushes are sent by Cloud Functions (BACKEND-SETUP §5); this section fixes what people see.

### 13.1 Notification priming
- **When:** once per install, as the §3.9 `.sheet` (medium detent) over the Map tab, only when all of these are true: signed in; in a family; the location prompt has been answered, whatever the answer (§10.2); notification permission is still not determined. Two permission asks never stack.
- **Copy:** title `Stay in the loop`; body `Get a heads-up when a family member checks in, and always for SOS alerts. You can change this any time in Settings.` (§6); PrimaryButton `Turn on notifications`; plain `Not now`.
- **Turn on notifications:** system prompt → dismiss on any answer; allowed → register for remote notifications and save the token to the owner-only doc `pushTokens/{uid}` (not `users/{uid}.fcmToken`) — family members can't read it.
- **Not now** (or swipe down): dismiss; the sheet never comes back. The only re-offer is the Settings row (§13.2). There is no timed re-ask (the old "7 days, max 2" rule is dropped).

### 13.2 Settings › Notifications
Rows follow the system permission, re-read on `scenePhase == .active` (e.g. coming back from iOS Settings):

| Permission | Rows | Footer (`.footnote` secondary) |
|---|---|---|
| Allowed / provisional | `Check-in alerts` Toggle (= `notifyOnCheckIn`, default on), subtitle `When someone opens Pinny or checks in.` · `SOS alerts` + trailing `Always on` (secondary, no toggle) | `SOS alerts can't be turned off — that's the point.` |
| Not determined (chose Not now) | `Turn on notifications` (`brandAccent` text row) → system prompt | `Get check-in and SOS alerts from your family.` |
| Denied | `Notifications are off` + trailing `Open Settings` → `UIApplication.openNotificationSettingsURLString` | `Turn them on so you don't miss an SOS.` |

- `SOS alerts · Always on` shows only when notifications are allowed; saying "always on" while iOS blocks them would be untrue.
- **Place names in alerts are not a setting:** a check-in alert always says `At {placeName}.` when one applies (§12.5).
- The toggle saves at once. **X:** it flips back and ErrorBanner `Couldn't save. Try again.`; offline → `You're offline. Check your connection.` (§9.1).

### 13.3 SOS
Entry: map SOS button (§11.3) or the full-drawer header `SOS` → SOS Confirm sheet (§3.8). Sheet body: location allowed → `Everyone gets an alert with your current location.`; denied / restricted → `Everyone gets an alert. Location is off, so it won't say where you are.`

**Hold to confirm (1.5 s)**
- Touch down: button scales 0.96; a 4 pt white ring, inset 6 pt, fills clockwise from 12 o'clock, linear, over 1.5 s.
- Haptics: `.light` impact at 0.5 s and 1.0 s; `.heavy` impact at 1.5 s, when it fires.
- Release early, or drag more than 44 pt off the button: the ring runs back to 0 in 0.2 s, nothing is sent, and `Keep holding to send.` (`.footnote` secondary) shows under the button for 2 s. No haptic.
- VoiceOver: the `Send SOS` custom action fires without a hold (§7). Reduce Motion: no fill animation; the ring jumps to full at 1.5 s; haptics unchanged.

**Send states** (replace the sheet content; swipe-to-dismiss is off until Sent or Failed):

| State | Shows | Behaviour |
|---|---|---|
| Sharing location | `ProgressView` + `Sharing your location…` | One fix, 3 s max. No fix → the device's cached fix if ≤ 2 min old, else carry on without a location. An SOS location can be up to 2 min older than its timestamp (cached fix), so an approximate position is sent rather than none. Location off → step skipped. |
| Sending | `ProgressView` + `Sending SOS…` | Reachability checked first. If there is a fix: `lastLocation` write with `src: "sos"`, then the message. 10 s timeout. |
| Sent | SF `checkmark.circle.fill` 48 pt · `SOS sent to your family` (`.title2` bold) · without a location, body `Sent without your location.` · bordered `Call 000` · PrimaryButton `Done` | `.success` haptic. No auto-dismiss: Call 000 stays until Done (the old 3 s auto-dismiss is dropped). |
| Failed | SF `exclamationmark.triangle.fill` `sosRedText` · offline `Couldn't send SOS. Check your connection, or call 000.` · other errors / timeout `Couldn't send SOS. Try again, or call 000.` · PrimaryButton `Try again` · bordered `Call 000` | `.error` haptic. Try again resends at once, no second hold — the user already confirmed. |

- `Call 000` opens `tel://000` (system call confirmation); the number is the Assumption 3 constant.
- The message ID is created before the first write and reused by Try again. If that document already exists (a timed-out write landed), show Sent — one SOS, never two.
- Location off: the SOS still sends, with no `lastLocation` write; the Sent state and the push both say so.

**SOS push (server; §6):** title `🚨 SOS from {name}`; body `Tap to see where they are.` when the SOS carried a location, else `Location unavailable.` "Carried a location" = the sender's `lastLocation.src == "sos"` and its `updatedAt` is no more than 60 s before the message's `createdAt`. Time-sensitive with sound (BACKEND §5); ignores `notifyOnCheckIn`.

**Stored message:** `type: "sos"`, `text: "SOS"` — fixed and never shown; clients draw the card below for `type == "sos"`.

**Chat SOS card (`SOSMessageCard`):** a system card, not a bubble: full width − 32, radius 12, `sosRed` fill, never grouped. Leading SF `sos` 24 pt white; `.headline` white `{name} sent an SOS · 3:41 pm` (`senderName`; mine `You sent an SOS · 3:41 pm`; time `h:mm a`, lowercase am/pm; the day comes from the separator). Below it a 44 pt bordered white button `Show on map` → Map tab, select that member, expand their drawer row, centre them (§10.8). Hidden when the sender has no location or has left the family; the card stays.

### 13.4 Chat
```
┌──────────────────────────────┐
│ Family                       │  inline nav title
├──────────────────────────────┤
│         Load earlier         │  only when older messages exist
│            Today             │  day separator
│     Mum                      │  sender name, first of group
│     ┌──────────────┐         │  others: .secondarySystemFill
│     │ Home by 6?   │         │
│     └──────────────┘         │
│ (M) ┌──────────────┐         │  avatar beside last of group
│     │ Bread too    │         │
│     └──────────────┘         │
│     3:12 pm                  │  time under last of group
│             ┌──────────────┐ │  mine: brandAccent / onAccent
│             │ Yes, leaving │ │
│             └──────────────┘ │
│                    Just now  │
│ ┌──────────────────────────┐ │
│ │ Sol sent an SOS · 3:42 pm│ │  SOSMessageCard (§13.3)
│ │ [ Show on map ]          │ │
│ └──────────────────────────┘ │
├──────────────────────────────┤
│ [ Message…              ](↑) │  input; counter from 900
└──────────────────────────────┘
```
- **Loading:** listen to the newest 100 messages (`createdAt` descending, limit 100), shown oldest → newest, newest at the bottom. If the page is full, a `Load earlier` row sits at the top; tapping it fetches the previous 100 once (spinner in the row) and keeps the scroll position. First load: centred `ProgressView`.
- **Scroll:** opens at the bottom. A new message scrolls into view only if I sent it or I'm within 80 pt of the bottom; otherwise a `New messages` capsule (SF `arrow.down`) sits above the input — tap to jump.
- **Grouping:** consecutive messages from one sender, each within 5 min of the previous one, form a group; a day separator or an SOS card ends it. Bubbles 2 pt apart inside a group, 12 pt between groups.
- **Others (left):** `.secondarySystemFill` / `.label`; first name `.caption` secondary above the first bubble; `AvatarView .small` beside the last bubble (photo or initials from the members list; a sender who has left → initials from `senderName`, grey). **Mine (right):** `brandAccent` / `onAccent`; no name or avatar. Bubble max width 75 %, radius 18 (§4).
- **Time:** under the last bubble of a group, `.caption2` tertiary: `Just now` under 60 s, `{n} min ago` under 60 min, then clock time `3:41 pm` (the separator carries the day). No "Updated" prefix (§8); refreshes on the §8 60 s timer.
- **Day separators:** centred `.caption` secondary: `Today`, `Yesterday`, weekday within 7 days (`Monday`), else `Mon 14 Sep` (add the year if not this year).
- **Input:** multi-line `TextField`, 1–5 lines then scrolls, placeholder `Message`. 1–1000 UTF-16 units after trimming (an emoji counts 2+, §6); typing stops at 1000. From 900, a counter `{n}/1000` (same UTF-16 count) (`.caption` secondary, monospaced digits) shows above the send button, `sosRedText` at 1000.
- **Send** (SF `arrow.up.circle.fill` 32 pt in a 44 pt target): disabled (`.tertiaryLabel`) when the trimmed text is empty; otherwise `brandAccent`. Tap → field clears and the bubble appears at once, `.light` haptic; the button never waits on the network.
- **Sending / failed:** a new bubble shows at 60 % opacity with `Sending…` (`.caption2`) under it until the write commits. Failure or 10 s timeout → SF `exclamationmark.circle.fill` `sosRedText` beside it and `Not sent. Tap to retry.` (`.caption2` `sosRedText`); tap → retry; long-press → `Retry` · `Delete` (local only — it was never sent). Failed sends are never retried automatically; only a tap or `Retry` resends (chat writes are transactions, so nothing is queued offline). The message ID is made before the first write, so a retry can't post twice (document exists → mark sent).
- **Offline:** reachability is checked before each send; offline → the bubble goes straight to failed. ErrorBanner `You're offline. Check your connection.` (§9.1) sits at the top of the list while offline and hides on reconnect; cached messages stay readable.
- **Empty:** `PinnyMascot` 60 × 72 pt, title `Say hi to your family` (`.title3`), message `Everyone in your family sees messages here.`; the input bar stays ready.
- **Keyboard:** input bar in `.safeAreaInset(edge: .bottom)`; showing the keyboard keeps the last message visible; drag the list down to dismiss it (`.scrollDismissesKeyboard(.interactively)`).
- Long-press a sent bubble → `Copy`. No edit or delete (rules forbid both).

### 13.5 Opening from a push
- **Check-in** (`type: "checkin"`, `uid`) → Map tab, select that member: centre them and expand their drawer row, lifting a collapsed drawer to half (§10.8).
- **SOS** (`type: "sos"`, `uid`) → the same for the sender. The SOS card is in Chat for later.
- **Cold start:** route once AuthGate reaches MainTabView. Signed out, or the member isn't in my family any more → open the Map tab and do nothing else.
- **In the foreground:** SOS shows as a banner with sound; check-in as a silent banner. A tap routes as above.
- **Chat messages:** no pushes in this stage.

### 13.6 Accessibility
- Bubble = one element: `Mum, Home by 6?, 3:12 pm` — the sender on every bubble, even where the name is hidden; mine `You, …`. Pending adds `, sending`; failed adds `, not sent`, hint `Double-tap to retry`, custom actions `Retry` and `Delete`. Sent bubbles have a `Copy` custom action.
- Day separators have the header trait; `Load earlier` is a button. Input label `Message`; the counter reads `912 of 1000 characters`; send label `Send` (dimmed when disabled).
- SOS card: one element `SOS. Sol sent an SOS at 3:42 pm`, then the button `Show Sol on map`. A new card is announced (§7).
- SOS sheet: each state change posts an announcement (`Sending SOS`, `SOS sent to your family`, or the failure string). `Call 000` label `Call triple zero`.
- Dynamic Type: bubbles grow vertically; Sent / Failed buttons stack full width at accessibility sizes; the hold button keeps a 64 pt minimum. Every control above ≥ 44 pt. The mascot is hidden from VoiceOver.
