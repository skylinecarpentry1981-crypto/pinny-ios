import SwiftUI
import GoogleSignIn

@main
struct FamilyMapApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.locationService)
                .environmentObject(appState.locationSync)
                .onAppear {
                    // Push taps go to AppState; one that launched the app is delivered now.
                    let appState = self.appState
                    appDelegate.onPushOpened = { route in
                        appState.handlePush(route)
                    }
                }
                // Google sign-in redirect (com.googleusercontent.apps.… URL scheme, project.yml).
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
