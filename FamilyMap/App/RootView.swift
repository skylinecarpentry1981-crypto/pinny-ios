import SwiftUI

/// Auth gate. Picks the top-level screen from `AppState.authState`.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch appState.authState {
            case .loading:
                SessionLoadingView()
            case .signedOut:
                WelcomeView()
            case .needsFamily:
                FamilyOnboardingView()
            case .ready:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.authState)
        .onAppear { appState.start() }
    }
}

/// Spinner while users/{uid} loads. After 8 s (e.g. offline with an empty cache), or on a session
/// error, shows a banner with Retry + Sign out so the user is never stuck.
private struct SessionLoadingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var timedOut = false
    @State private var attempt = 0

    private static let timeout: UInt64 = 8_000_000_000

    var body: some View {
        Group {
            if let message = appState.sessionError ?? (timedOut ? AppError.offline : nil) {
                VStack(spacing: FMSpacing.xl) {
                    Spacer()
                    ErrorBanner(message: message)
                    PrimaryButton(title: "Retry") {
                        timedOut = false
                        attempt += 1
                        appState.retrySession()
                    }
                    Button("Sign out") {
                        appState.signOut()
                    }
                    .frame(minHeight: FMSize.minTapTarget)
                    Spacer()
                }
                .padding(FMSpacing.xl)
                .background(Color.fm.background)
            } else {
                LoadingView()
            }
        }
        .task(id: attempt) {
            try? await Task.sleep(nanoseconds: Self.timeout)
            guard !Task.isCancelled else { return }
            timedOut = true
        }
    }
}
