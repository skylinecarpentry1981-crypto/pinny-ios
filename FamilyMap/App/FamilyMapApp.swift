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
                .environmentObject(appState.passService)
                .environmentObject(appState.photoService)
                .onAppear {
                    // Push taps go to AppState; one that launched the app is delivered now.
                    let appState = self.appState
                    appDelegate.onPushOpened = { route in
                        appState.handlePush(route)
                    }
                    // Stage 9: an SOS banner shown while Pinny is open is acknowledged (no tab switch).
                    appDelegate.onSOSPresented = { route in
                        appState.acknowledgeSOSPush(route)
                    }
                    // Stage 10: an Ask location banner shown while Pinny is active shares once (no tab switch).
                    appDelegate.onPingPresented = { route in
                        appState.sharePingLocation(route)
                    }
                }
                // Google sign-in redirect (com.googleusercontent.apps.… URL scheme, project.yml).
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
