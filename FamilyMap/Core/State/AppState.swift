import Foundation
import UIKit
import Combine
import CoreLocation
import UserNotifications

/// Tabs in `MainTabView`. Lives here so any screen can switch tabs (Family row pin -> Map).
enum MainTab: Hashable {
    case map
    case chat
    case family
}

/// App-wide session state. Injected via `.environmentObject`.
@MainActor
final class AppState: ObservableObject {
    enum AuthState: Equatable {
        case loading
        case signedOut
        case needsFamily
        case ready
    }

    @Published private(set) var authState: AuthState = .loading {
        didSet {
            if authState != oldValue {
                applyPendingPushRoute()
                applyPendingSOSAck()
                applyPendingPingShare()
            }
        }
    }
    @Published private(set) var currentUser: AppUser?
    @Published private(set) var family: Family?
    @Published private(set) var members: [AppUser] = []
    /// Family Places (families/{familyId}/places), live while the family listeners run.
    @Published private(set) var places: [Place] = []
    /// False until the first `places` snapshot of the current family; the Family tab shows a skeleton row.
    @Published private(set) var hasLoadedPlaces = false
    /// Where the Map tab was last looking. Not published (the map pans constantly); read once by the
    /// place editor as its fallback opening centre.
    var lastMapCentre: CLLocationCoordinate2D?
    /// Set when the users/{uid} listener or bootstrap fails; RootView surfaces it.
    @Published var sessionError: String?
    /// One-off message for the next screen (e.g. "Your account has been deleted." on Welcome).
    @Published var transientMessage: String?
    @Published var selectedTab: MainTab = .map
    /// Set by the Family tab's pin button; MapView centres on this member, opens their card, then clears it.
    @Published var focusMemberId: String?
    /// The system notification permission; nil until first read. Drives Settings › Notifications and
    /// the priming sheet (DESIGN-SPEC §13.1–13.2).
    @Published private(set) var notificationStatus: UNAuthorizationStatus?

    let authService: AuthService
    let familyService: FamilyService
    let placeService: PlaceService
    let locationService: LocationService
    let locationSync: LocationSync
    let chatService: ChatService
    let notificationService: NotificationService
    /// Family Pass (Stage 7): StoreKit purchase / restore + `redeemFamilyPass`.
    let passService: PassService
    /// Profile photo (Stage 8): Storage upload + `users/{uid}.photoURL`.
    let photoService: PhotoService

    private var didStart = false
    /// The first auth callback must always be handled, even when it reports nil (signed out).
    private var didReceiveAuth = false
    private var observedUid: String?
    private var observedFamilyId: String?
    private var isCreatingUserDoc = false
    private var isSeedingProviderPhoto = false
    /// True between "family created" and "Continue" so onboarding can show the invite code first.
    private var holdOnboarding = false

    private var userListener: ListenerCancel?
    private var familyListener: ListenerCancel?
    private var membersListener: ListenerCancel?
    private var placesListener: ListenerCancel?

    /// False until the first members snapshot of the current family; a pending push route waits for it.
    private var hasLoadedMembers = false
    /// A tapped push that can't be routed yet (cold start: the session or family is still loading).
    private var pendingPushRoute: PushRoute?
    /// A tapped SOS push whose ack waits for the session (Stage 9).
    private var pendingSOSAck: PushRoute?
    /// An "Ask location" push whose one share waits for the session (Stage 10).
    private var pendingPingShare: PushRoute?
    /// Between the push-token delete and Auth sign-out; no token is saved meanwhile.
    private var isSigningOut = false
    private var tokenRefreshObserver: AnyCancellable?

    /// A settings write offline would wait for the network; fail after this instead.
    private static let settingsTimeoutNanoseconds: UInt64 = 10_000_000_000

    init(
        authService: AuthService = FirebaseAuthService(),
        familyService: FamilyService = FirebaseFamilyService(),
        placeService: PlaceService = FirebasePlaceService(),
        locationService: LocationService = LocationService(),
        chatService: ChatService = FirestoreChatService(),
        notificationService: NotificationService = FirebaseNotificationService(),
        passService: PassService? = nil   // default built inside the @MainActor init (PassService is main-actor isolated)
    ) {
        self.authService = authService
        self.familyService = familyService
        self.placeService = placeService
        self.locationService = locationService
        self.locationSync = LocationSync(locationService: locationService, familyService: familyService)
        self.chatService = chatService
        self.notificationService = notificationService
        self.passService = passService ?? PassService()
        self.photoService = PhotoService(familyService: familyService)
        locationSync.sharingUserId = { [weak self] in
            guard let self, self.authState == .ready else { return nil }
            return self.currentUser?.id
        }
        // FCM issued a (new) token: save it for the signed-in user.
        tokenRefreshObserver = NotificationCenter.default.publisher(for: .fcmTokenRefreshed)
            .sink { [weak self] notification in
                let token = notification.userInfo?["token"] as? String
                Task { @MainActor in
                    self?.syncPushToken(token)
                }
            }
    }

    /// Starts the Firebase Auth listener. Safe to call more than once.
    func start() {
        guard !didStart else { return }
        didStart = true
        // StoreKit `Transaction.updates` listener for the whole app life (Ask to Buy, other devices,
        // transactions left unfinished because the server call failed last time).
        passService.start()
        authService.observeAuthState { [weak self] uid in
            Task { @MainActor in
                self?.handleAuthChange(uid: uid)
            }
        }
    }

    // MARK: - Auth + user doc

    private func handleAuthChange(uid: String?) {
        guard !didReceiveAuth || uid != observedUid else { return }
        didReceiveAuth = true
        stopUserListener()
        stopFamilyListeners()
        observedUid = uid
        holdOnboarding = false
        sessionError = nil
        locationSync.reset()
        selectedTab = .map
        focusMemberId = nil
        lastMapCentre = nil

        guard let uid else {
            currentUser = nil
            family = nil
            members = []
            places = []
            authState = .signedOut
            return
        }

        authState = .loading
        startUserListener(uid: uid)
        // Launch or sign-in: make sure this phone's token is saved for this account.
        syncPushToken()
    }

    private func startUserListener(uid: String) {
        userListener = familyService.observeUser(id: uid) { [weak self] event in
            Task { @MainActor in
                self?.handleUserEvent(event, uid: uid)
            }
        }
    }

    /// Retry from the stuck-loading screen (offline, empty cache): re-attach the users/{uid} listener.
    func retrySession() {
        guard let uid = observedUid else { return }
        stopUserListener()
        sessionError = nil
        startUserListener(uid: uid)
    }

    private func handleUserEvent(_ event: UserSnapshotEvent, uid: String) {
        guard uid == observedUid else { return }
        switch event {
        case .failure(let error):
            sessionError = error.userMessage
        case .user(nil, _, _):
            createUserDocIfNeeded(uid: uid)
        case .user(let user?, let hasPendingWrites, let isFromCache):
            currentUser = user
            sessionError = nil
            resolveState(startListeners: !hasPendingWrites)
            if !isFromCache, !hasPendingWrites, user.photoURL == nil {
                seedProviderPhotoIfNeeded(uid: uid)
            }
        }
    }

    /// Backfill for user docs created before Stage 8: copy the Google picture into `photoURL` once.
    /// Only after a server snapshot with no photo, and never again for a uid once the flag is set
    /// (after this seed, or after the user uploads or removes a photo themselves).
    private func seedProviderPhotoIfNeeded(uid: String) {
        guard !isSeedingProviderPhoto,
              !PhotoService.didSeedProviderPhoto(uid: uid),
              let url = authService.providerPhotoURL else { return }
        isSeedingProviderPhoto = true
        let familyService = self.familyService
        Task {
            defer { isSeedingProviderPhoto = false }
            do {
                try await familyService.updatePhotoURL(userId: uid, url: url)
                PhotoService.markProviderPhotoSeeded(uid: uid)
            } catch {
                // Best effort; the next server snapshot without a photo retries.
            }
        }
    }

    private func createUserDocIfNeeded(uid: String) {
        guard !isCreatingUserDoc else { return }
        isCreatingUserDoc = true
        // Google picture only on create (Stage 8); a photo the user chose later is never overwritten.
        let user = AppUser(id: uid, name: seedName(), photoURL: authService.currentPhotoURL)
        Task {
            defer { isCreatingUserDoc = false }
            do {
                try await familyService.createUser(user)
            } catch {
                sessionError = error.userMessage
            }
        }
    }

    /// Apple full name -> email local-part -> "Family member". Rules require 1-40 UTF-16 units.
    private func seedName() -> String {
        var candidate = authService.currentDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if candidate.isEmpty, let email = authService.currentEmail, let local = email.split(separator: "@").first {
            candidate = String(local)
        }
        if candidate.isEmpty {
            candidate = "Family member"
        }
        return candidate.clamped(toUTF16: 40)
    }

    /// Derives `authState` from the user doc and (re)starts family listeners when the family changes.
    private func resolveState(startListeners: Bool) {
        guard let familyId = currentUser?.familyId else {
            stopFamilyListeners()
            family = nil
            members = []
            places = []
            authState = .needsFamily
            return
        }
        if startListeners, familyId != observedFamilyId {
            startFamilyListeners(familyId: familyId)
        }
        authState = holdOnboarding ? .needsFamily : .ready
    }

    // MARK: - Family listeners

    private func startFamilyListeners(familyId: String) {
        stopFamilyListeners()
        observedFamilyId = familyId
        familyListener = familyService.observeFamily(id: familyId) { [weak self] family in
            Task { @MainActor in
                guard self?.observedFamilyId == familyId else { return }
                self?.family = family
            }
        }
        membersListener = familyService.observeMembers(familyId: familyId) { [weak self] members in
            Task { @MainActor in
                guard let self, self.observedFamilyId == familyId else { return }
                self.members = members
                self.hasLoadedMembers = true
                self.applyPendingPushRoute()
            }
        }
        placesListener = placeService.observePlaces(familyId: familyId) { [weak self] places in
            Task { @MainActor in
                guard self?.observedFamilyId == familyId else { return }
                self?.places = places
                self?.hasLoadedPlaces = true
            }
        }
    }

    private func stopFamilyListeners() {
        familyListener?()
        membersListener?()
        placesListener?()
        familyListener = nil
        membersListener = nil
        placesListener = nil
        observedFamilyId = nil
        hasLoadedPlaces = false
        hasLoadedMembers = false
    }

    private func stopUserListener() {
        userListener?()
        userListener = nil
    }

    // MARK: - Actions

    /// Called after a successful join. The batch has committed, so listeners are safe to start.
    func didJoin(_ family: Family) {
        self.family = family
        currentUser?.familyId = family.id
        if let id = family.id {
            startFamilyListeners(familyId: id)
        }
        authState = .ready
    }

    /// Called after a successful create. Stays on onboarding until `continueAfterCreate()`.
    func didCreate(_ family: Family) {
        holdOnboarding = true
        self.family = family
        currentUser?.familyId = family.id
        if let id = family.id {
            startFamilyListeners(familyId: id)
        }
    }

    func continueAfterCreate() {
        holdOnboarding = false
        resolveState(startListeners: true)
    }

    func leaveFamily() async throws {
        guard let family else { return }
        let previousId = observedFamilyId
        stopFamilyListeners()
        do {
            try await familyService.leaveFamily(family)
        } catch {
            if let previousId {
                startFamilyListeners(familyId: previousId)
            }
            throw error
        }
        currentUser?.familyId = nil
        self.family = nil
        members = []
        places = []
        locationSync.reset()
        authState = .needsFamily
    }

    // MARK: - Places

    /// A document ID for a new place, made once per editor session and reused by every retry.
    func newPlaceId() -> String? {
        guard let familyId = currentUser?.familyId else { return nil }
        return placeService.newPlaceId(familyId: familyId)
    }

    /// The 10-place limit is the client's job (rules cannot count documents). A retry's own place,
    /// already in `places` from the first attempt's local write, doesn't count.
    func addPlace(_ draft: PlaceDraft, placeId: String) async throws {
        guard let familyId = currentUser?.familyId else { throw PlaceError.saveFailed }
        guard places.filter({ $0.id != placeId }).count < Place.maxPerFamily else { throw PlaceError.limitReached }
        try await placeService.addPlace(familyId: familyId, placeId: placeId, draft: draft)
    }

    func updatePlace(_ place: Place, with draft: PlaceDraft) async throws {
        guard let familyId = currentUser?.familyId, let placeId = place.id else { throw PlaceError.saveFailed }
        try await placeService.updatePlace(familyId: familyId, placeId: placeId, draft: draft)
    }

    func deletePlace(_ place: Place) async throws {
        guard let familyId = currentUser?.familyId, let placeId = place.id else { throw PlaceError.deleteFailed }
        try await placeService.deletePlace(familyId: familyId, placeId: placeId)
    }

    func updateName(_ name: String) async throws {
        guard let uid = currentUser?.id else { throw FamilyError.notSignedIn }
        try await familyService.updateName(userId: uid, name: name)
        currentUser?.name = name
    }

    /// BACKEND-SETUP §7 order: pushTokens/{uid} is deleted while still signed in (the delete needs the
    /// session), then Auth signs out, then this phone's FCM token is deleted so the next account here
    /// gets a new one. Both token steps are best effort; offline skips the delete.
    func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        let uid = observedUid
        let isOnline = locationSync.isOnline
        let notificationService = self.notificationService
        Task {
            if let uid, isOnline {
                await notificationService.removeToken(userId: uid)
            }
            stopFamilyListeners()
            do {
                try authService.signOut()
            } catch {
                isSigningOut = false
                sessionError = error.userMessage
                // Still signed in: save the token again.
                syncPushToken()
                return
            }
            isSigningOut = false
            await notificationService.deleteLocalToken()
        }
    }

    /// Called once `AuthService.deleteAccount` succeeds; the auth listener then routes to Welcome.
    /// The server removes pushTokens/{uid}; only this phone's FCM token is deleted here.
    func didDeleteAccount() {
        stopFamilyListeners()
        transientMessage = "Your account has been deleted."
        let notificationService = self.notificationService
        Task {
            await notificationService.deleteLocalToken()
        }
    }

    // MARK: - Notifications

    /// Re-reads the system permission (MainTabView: on open and on every return to the foreground).
    /// Turned on since the last read (priming sheet, Settings row or iOS Settings) -> save the token.
    func refreshNotificationStatus() async {
        let previous = notificationStatus
        let status = await notificationService.authorizationStatus()
        notificationStatus = status
        if let previous, !previous.allowsAlerts, status.allowsAlerts {
            syncPushToken()
        }
    }

    /// The system prompt (priming sheet and the Settings row), then a fresh status.
    func requestNotificationPermission() async {
        _ = await notificationService.requestPermission()
        await refreshNotificationStatus()
    }

    /// Settings › Check-in alerts: `notifyOnCheckIn` alone plus `updatedAt`. Fails after 10 s.
    func setNotifyOnCheckIn(_ enabled: Bool) async throws {
        guard let uid = currentUser?.id else { throw FamilyError.notSignedIn }
        let familyService = self.familyService
        try await withTimeout(nanoseconds: Self.settingsTimeoutNanoseconds, timeoutError: FamilyError.unknown) {
            try await familyService.updateNotifyOnCheckIn(userId: uid, enabled: enabled)
        }
        currentUser?.notifyOnCheckIn = enabled
    }

    // MARK: - Ask location (Stage 10)

    /// Asks `member` to share where they are: one `pings` doc, the server sends them the push.
    /// Offline is checked first and the write is a transaction, so nothing is queued for later.
    /// Throws `FamilyError.network` offline, `AskLocationError` for anything else.
    func askLocation(_ member: AppUser) async throws {
        guard locationSync.isOnline else { throw FamilyError.network }
        let firstName = member.firstName
        guard let me = currentUser, let familyId = me.familyId, let toUid = member.id, toUid != me.id else {
            throw AskLocationError(firstName: firstName)
        }
        let familyService = self.familyService
        let fromName = me.name
        do {
            try await withTimeout(nanoseconds: Self.settingsTimeoutNanoseconds, timeoutError: FamilyError.unknown) {
                try await familyService.askLocation(familyId: familyId, to: toUid, fromName: fromName)
            }
        } catch {
            if FamilyError.from(error) == .network { throw FamilyError.network }
            throw AskLocationError(firstName: firstName)
        }
    }

    /// Saves this phone's FCM token for the signed-in user. The service writes only while
    /// notifications are allowed and when pushTokens/{uid} is missing or holds another token.
    /// `token`: the one FCM just issued; nil uses the current one.
    private func syncPushToken(_ token: String? = nil) {
        guard let uid = observedUid, !isSigningOut else { return }
        let notificationService = self.notificationService
        Task {
            await notificationService.syncToken(userId: uid, token: token)
        }
    }

    // MARK: - Push taps

    /// A tapped push (DESIGN-SPEC §13.5): always the Map tab; for a check-in or SOS from someone in my
    /// family, also select them (MapView centres them and expands their drawer row). On a cold start
    /// the route waits until the session and the family's members have loaded.
    /// An "Ask location" push (Stage 10): the Map tab and one manual share.
    func handlePush(_ route: PushRoute) {
        selectedTab = .map
        acknowledgeSOSPush(route)
        sharePingLocation(route)
        guard route.type == "checkin" || route.type == "sos", route.uid != nil, route.familyId != nil else {
            pendingPushRoute = nil
            return
        }
        pendingPushRoute = route
        applyPendingPushRoute()
    }

    private func applyPendingPushRoute() {
        guard let route = pendingPushRoute else { return }
        switch authState {
        case .loading:
            // Keep it until the session resolves.
            return
        case .signedOut, .needsFamily:
            // Signed out or no family: the Map tab only, nothing else.
            pendingPushRoute = nil
        case .ready:
            guard hasLoadedMembers else { return }
            pendingPushRoute = nil
            guard let uid = route.uid,
                  route.familyId == currentUser?.familyId,
                  members.contains(where: { $0.id == uid }) else { return }
            selectedTab = .map
            focusMemberId = uid
        }
    }

    // MARK: - Ask location push (Stage 10)

    /// An "Ask location" push the user tapped, or saw as a banner while Pinny was active
    /// (AppDelegate): share once, like Check in. Never switches tabs by itself.
    func sharePingLocation(_ route: PushRoute) {
        guard route.type == "ping", route.familyId != nil else { return }
        pendingPingShare = route
        applyPendingPingShare()
    }

    /// The share runs at once, or as soon as the session is ready (cold start from the push).
    /// Location off: `share` does nothing and the Map's "Location is off" banner explains it.
    private func applyPendingPingShare() {
        guard let route = pendingPingShare else { return }
        switch authState {
        case .loading:
            return
        case .signedOut, .needsFamily:
            pendingPingShare = nil
        case .ready:
            pendingPingShare = nil
            guard route.familyId == currentUser?.familyId else { return }
            let locationSync = self.locationSync
            Task {
                await locationSync.share(source: .manual)
            }
        }
    }

    // MARK: - SOS acknowledgement (Stage 9)

    /// Opening Pinny acknowledges recent SOS messages from the family, so the server stops repeating
    /// the alert to this member. Called by MainTabView when it appears (the session became ready) and
    /// on every return to the foreground. Never from a background launch: the user hasn't seen anything yet.
    func acknowledgeRecentSOS() {
        guard authState == .ready,
              let familyId = currentUser?.familyId,
              UIApplication.shared.applicationState != .background else { return }
        let chatService = self.chatService
        Task {
            await chatService.acknowledgeRecentSOS(familyId: familyId)
        }
    }

    /// An SOS push the user tapped, or saw as a banner while Pinny was open (AppDelegate): its
    /// message is acknowledged. Never switches tabs.
    func acknowledgeSOSPush(_ route: PushRoute) {
        guard route.type == "sos", route.familyId != nil, route.messageId != nil else { return }
        pendingSOSAck = route
        applyPendingSOSAck()
    }

    /// The SOS push's own message: acknowledged at once, or as soon as the session is ready.
    private func applyPendingSOSAck() {
        guard let route = pendingSOSAck else { return }
        switch authState {
        case .loading:
            return
        case .signedOut, .needsFamily:
            pendingSOSAck = nil
        case .ready:
            pendingSOSAck = nil
            guard let familyId = route.familyId,
                  let messageId = route.messageId,
                  familyId == currentUser?.familyId else { return }
            let chatService = self.chatService
            Task {
                await chatService.acknowledgeSOS(familyId: familyId, messageId: messageId)
            }
        }
    }
}
