import Foundation
import UIKit
import UserNotifications
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

/// Push permission and this phone's FCM token (BACKEND-SETUP §7). The token lives in the owner-only
/// doc pushTokens/{uid} = { token, updatedAt }, never on users/{uid} (family can read those).
protocol NotificationService: AnyObject {
    /// System prompt for alert, sound and badge. Returns true when allowed; then registers for
    /// remote notifications so APNs (and so FCM) has a token.
    func requestPermission() async -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    /// When notifications are allowed: reads pushTokens/{uid} from the server and writes
    /// `{ token, updatedAt }` only if it is missing or holds a different token. Best effort.
    /// `token` is the one FCM just issued; nil uses the current one.
    func syncToken(userId: String, token: String?) async
    /// Sign-out, while still signed in: deletes pushTokens/{uid}. Best effort.
    func removeToken(userId: String) async
    /// Deletes this phone's FCM token so the next account here gets a new one. Best effort.
    func deleteLocalToken() async
}

extension UNAuthorizationStatus {
    /// Allowed in any form (provisional and ephemeral included).
    var allowsAlerts: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

final class FirebaseNotificationService: NotificationService {
    /// Offline, a Firestore delete or `deleteToken` would wait for the network; sign-out must not.
    private static let bestEffortTimeoutNanoseconds: UInt64 = 5_000_000_000

    /// Computed so `Firestore.firestore()` is never called before `FirebaseApp.configure()`.
    private var pushTokens: CollectionReference { Firestore.firestore().collection("pushTokens") }

    func requestPermission() async -> Bool {
        let granted: Bool
        do {
            granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            granted = false
        }
        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        return granted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func syncToken(userId: String, token: String?) async {
        guard await authorizationStatus().allowsAlerts else { return }
        guard let token = token ?? Messaging.messaging().fcmToken, !token.isEmpty else { return }
        let ref = pushTokens.document(userId)
        do {
            // Server read, not the cache: the server may have removed a dead or reused token.
            let stored = try await ref.getDocument(source: .server)
            if stored.get("token") as? String == token { return }
            // Signed out (or switched account) while reading: don't hand this phone to the old account.
            guard Auth.auth().currentUser?.uid == userId else { return }
            try await ref.setData([
                "token": token,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch {
            // Best effort: the next launch, sign-in or token refresh tries again.
        }
    }

    func removeToken(userId: String) async {
        let ref = pushTokens.document(userId)
        try? await withTimeout(
            nanoseconds: Self.bestEffortTimeoutNanoseconds,
            timeoutError: FamilyError.network
        ) {
            try await ref.delete()
        }
    }

    func deleteLocalToken() async {
        try? await withTimeout(
            nanoseconds: Self.bestEffortTimeoutNanoseconds,
            timeoutError: FamilyError.network
        ) {
            try await Messaging.messaging().deleteToken()
        }
    }
}
