import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

extension Notification.Name {
    /// Posted with userInfo["token"] (String) whenever FCM issues a new registration token.
    static let fcmTokenRefreshed = Notification.Name("FamilyMap.fcmTokenRefreshed")
}

/// What a tapped push asks for (BACKEND-SETUP §5 "Push payloads"). The FCM `data` keys arrive at the
/// top level of `userInfo`, as strings; any of them may be missing.
struct PushRoute: Equatable {
    /// "checkin" or "sos"; anything else just opens the Map tab.
    let type: String?
    let uid: String?
    let familyId: String?

    init(userInfo: [AnyHashable: Any]) {
        type = userInfo["type"] as? String
        uid = userInfo["uid"] as? String
        familyId = userInfo["familyId"] as? String
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `FamilyMapApp` once `AppState` exists. A tap that arrives earlier (cold start from a
    /// push) waits in `pendingPush` and is handed over when this is set.
    @MainActor var onPushOpened: (@MainActor (PushRoute) -> Void)? {
        didSet { deliverPendingPush() }
    }
    @MainActor private var pendingPush: PushRoute?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        // No prompt: this only gets an APNs token. The permission ask is the priming sheet (§13.1).
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    @MainActor private func openPush(_ route: PushRoute) {
        if let onPushOpened {
            onPushOpened(route)
        } else {
            pendingPush = route
        }
    }

    @MainActor private func deliverPendingPush() {
        guard let route = pendingPush, let onPushOpened else { return }
        pendingPush = nil
        onPushOpened(route)
    }
}

// MARK: - MessagingDelegate

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        // AppState saves it to pushTokens/{uid} (when signed in and notifications are allowed).
        NotificationCenter.default.post(
            name: .fcmTokenRefreshed,
            object: nil,
            userInfo: ["token": fcmToken]
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// In the foreground: SOS as a banner with sound, check-in as a silent banner (§13.5).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let route = PushRoute(userInfo: notification.request.content.userInfo)
        completionHandler(route.type == "sos" ? [.banner, .sound, .list] : [.banner, .list])
    }

    /// A tap: AppState opens the Map tab and, when the sender is in my family, selects them (§13.5).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            self.openPush(route)
        }
        completionHandler()
    }
}
