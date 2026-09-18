# Stage 8 — Profile photos

Owner request (2026-09-18): show family members' faces on the map pins and in the member list.

## 1. Sources
- **Google sign-in:** on first sign-in, copy the Google profile picture URL into `users/{uid}.photoURL` (client, same path as the display name seeding). Apple/email sign-ins get no automatic photo.
- **Photo library:** Settings › Profile photo → `PhotosPicker` (iOS 16, no permission string needed: the picker runs out of process). No camera in Stage 8.

## 2. Storage
- Firebase Storage bucket of the project; path `avatars/{uid}.jpg`.
- Client resizes to 512×512 (centre-crop square), JPEG quality 0.8, expected ≤ 200 KB; hard limit in rules 2 MB, content type `image/jpeg`.
- Storage rules: write only by the owner (`request.auth.uid == uid`), size/type checked; read by any signed-in user (URLs are unguessable download URLs anyway; family-only read would need cross-service rules and is not worth it for a profile picture).
- After upload, the client writes the download URL to `users/{uid}.photoURL` (already allowed by `validUser`; verify the rules accept a string ≤ 2048 chars) with `updatedAt: serverTimestamp()`.
- Remove photo: delete the Storage object (best effort) and set `photoURL` to null.
- `onUserDeleted` deletes `avatars/{uid}.jpg` (Admin SDK, ignore not-found).

## 3. UI (Designer §15)
- Settings › Profile: avatar (80 pt) + "Change photo" / "Remove photo"; states: picking, uploading (spinner on the avatar), failed (ErrorBanner "Couldn't update your photo. Try again."), success (haptic).
- Wherever `AvatarView` is used (map pins, drawer rows, member rows, chat bubbles): photo if `photoURL`, else initials — unchanged behaviour, just make sure `AsyncImage` shows the initials while loading and on failure, and caches (URLCache is fine).
- Privacy: PrivacyInfo.xcprivacy adds "Photos or Videos" (linked, not tracking, App Functionality); privacy.html + BACKEND §9 add the profile photo (stored in Sydney, visible to signed-in users of the app, deleted with the account); App Store privacy answers row.

## 4. Constraints
- iOS 16.0, Swift 5.9, no force unwraps, `error.userMessage`, English, no background-location changes.
- `firebase/storage.rules` added to `firebase.json`; deployed with `firebase deploy --only storage`.
