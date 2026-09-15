import SwiftUI
import AuthenticationServices

@MainActor
final class WelcomeViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isBusy = false

    private var currentNonce: String?

    /// Called from `SignInWithAppleButton.onRequest`: fresh nonce, SHA256 to Apple, raw kept for Firebase.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Nonce.random()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256(nonce)
    }

    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>, authService: AuthService) {
        switch result {
        case .success(let authorization):
            guard let rawNonce = currentNonce else {
                errorMessage = AuthError.appleFailed.userMessage
                return
            }
            currentNonce = nil
            isBusy = true
            errorMessage = nil
            Task {
                defer { isBusy = false }
                do {
                    try await authService.signInWithApple(authorization: authorization, rawNonce: rawNonce)
                } catch {
                    errorMessage = error.userMessage
                }
            }
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            errorMessage = AuthError.appleFailed.userMessage
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = WelcomeViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: FMSpacing.xl) {
                Spacer()

                BobbingMascot()

                VStack(spacing: FMSpacing.sm) {
                    Text("Pinny")
                        .font(.largeTitle.bold())

                    Text("Your family, one tap away")
                        .font(.title3)
                        .foregroundColor(Color.fm.textSecondary)
                        .multilineTextAlignment(.center)

                    Text("Shares your location only when you open the app.")
                        .font(.footnote)
                        .foregroundColor(Color.fm.textSecondary)
                        .multilineTextAlignment(.center)
                }

                if let message = appState.transientMessage {
                    InfoBanner(systemImage: "checkmark.circle", message: message)
                }

                Spacer()

                ZStack {
                    SignInWithAppleButton(.signIn) { request in
                        viewModel.prepare(request)
                    } onCompletion: { result in
                        viewModel.handleAppleSignIn(result, authService: appState.authService)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: FMSize.buttonHeight)
                    .opacity(viewModel.isBusy ? 0.4 : 1)
                    .disabled(viewModel.isBusy)

                    if viewModel.isBusy {
                        ProgressView()
                    }
                }

                NavigationLink("Use email instead") {
                    EmailSignInView()
                }
                .font(.footnote)
                .foregroundColor(Color.fm.textSecondary)
                .frame(minHeight: FMSize.minTapTarget)
                .disabled(viewModel.isBusy)

                // TODO(stage 6): link Terms and Privacy to their hosted URLs.
                Text("By continuing you agree to Terms · Privacy")
                    .font(.caption2)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
                    .multilineTextAlignment(.center)

                if let errorMessage = viewModel.errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            .padding(FMSpacing.xl)
            .background(Color.fm.background)
        }
        .onDisappear {
            appState.transientMessage = nil
        }
    }
}

/// DESIGN-SPEC §3.1: the Pinny mascot, 120 × 144 pt (80 × 96 at accessibility text sizes so the
/// buttons stay on screen on SE). Idle bob 0 → −6 pt → 0 over 2 s while on screen; static under
/// Reduce Motion. Decorative, hidden from VoiceOver.
private struct BobbingMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isUp = false

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        Image("PinnyMascot")
            .resizable()
            .scaledToFit()
            .frame(width: isLarge ? 80 : 120, height: isLarge ? 96 : 144)
            .offset(y: isUp ? -6 : 0)
            .accessibilityHidden(true)
            .onAppear { startBobbing() }
            .onDisappear { isUp = false }
            .onChange(of: reduceMotion) { _ in startBobbing() }
    }

    /// One second up, one second down, repeating: a 2 s cycle.
    private func startBobbing() {
        guard !reduceMotion else {
            // Replaces the repeating animation with a still mascot.
            withAnimation(nil) { isUp = false }
            return
        }
        isUp = false
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            isUp = true
        }
    }
}
