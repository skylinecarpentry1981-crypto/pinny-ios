import SwiftUI
import AuthenticationServices

/// State machine for Apple 5.1.1(v) account deletion (DESIGN-SPEC §9.4):
/// idle -> confirm1 (alert) -> confirm2 (destructive confirm) -> deleting
///   -> done, or on `.requiresRecentLogin` -> reauth (apple | password) -> deleting -> done.
/// "deleting" is `isDeleting` on top of the step it started from, so that screen shows the spinner
/// and disables Cancel. Any other failure stays on the same step with `errorMessage`.
@MainActor
final class DeleteAccountViewModel: ObservableObject {
    enum Step: Equatable {
        case idle
        case confirm1
        case confirm2
        case reauthApple
        case reauthPassword
        case done
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var isDeleting = false
    @Published private(set) var errorMessage: String?
    @Published var password = ""

    private var currentNonce: String?

    var isAlertPresented: Bool { step == .confirm1 }

    var isSheetPresented: Bool {
        switch step {
        case .confirm2, .reauthApple, .reauthPassword: return true
        case .idle, .confirm1, .done: return false
        }
    }

    func begin() {
        reset()
        step = .confirm1
    }

    func cancel() {
        guard !isDeleting else { return }
        reset()
    }

    func acceptFirstConfirmation() {
        step = .confirm2
    }

    /// Step 2. Apple users always re-run Sign in with Apple so the token can be revoked (Apple requires
    /// revocation on deletion, even for a fresh session). Email users delete first and re-auth only
    /// on `.requiresRecentLogin`.
    func confirmDelete(appState: AppState) {
        if appState.authService.currentProvider == .apple {
            errorMessage = nil
            step = .reauthApple
            return
        }
        delete(with: nil, appState: appState)
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Nonce.random()
        currentNonce = nonce
        request.requestedScopes = []
        request.nonce = Nonce.sha256(nonce)
    }

    func handleAppleReauth(_ result: Result<ASAuthorization, Error>, appState: AppState) {
        switch result {
        case .success(let authorization):
            guard let rawNonce = currentNonce else {
                errorMessage = AuthError.appleFailed.userMessage
                return
            }
            currentNonce = nil
            delete(with: .apple(authorization, rawNonce: rawNonce), appState: appState)
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            errorMessage = AuthError.appleFailed.userMessage
        }
    }

    func deleteWithPassword(appState: AppState) {
        guard !password.isEmpty else { return }
        delete(with: .password(password), appState: appState)
    }

    private func delete(with reauth: Reauthentication?, appState: AppState) {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            defer { isDeleting = false }
            do {
                try await appState.authService.deleteAccount(reauth: reauth)
                step = .done
                appState.didDeleteAccount()
            } catch {
                handleFailure(error, provider: appState.authService.currentProvider)
            }
        }
    }

    private func handleFailure(_ error: Error, provider: AuthProvider) {
        // Only a stale session moves to re-auth; the .info banner on that step explains why.
        guard (error as? AuthError) == .requiresRecentLogin, step == .confirm2 else {
            errorMessage = error.userMessage
            return
        }
        switch provider {
        case .apple: step = .reauthApple
        case .password: step = .reauthPassword
        case .unknown: errorMessage = error.userMessage
        }
    }

    private func reset() {
        step = .idle
        errorMessage = nil
        password = ""
        currentNonce = nil
    }
}

/// Sheet content for confirm2 and the re-auth steps.
struct DeleteAccountSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: DeleteAccountViewModel
    @Environment(\.colorScheme) private var colorScheme

    private static let deletedItems = ["Account", "Name", "Last location", "Family membership"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: FMSpacing.xl) {
                    if let errorMessage = viewModel.errorMessage {
                        ErrorBanner(message: errorMessage)
                    }

                    content

                    Button("Cancel") { viewModel.cancel() }
                        .frame(minHeight: FMSize.minTapTarget)
                        .disabled(viewModel.isDeleting)
                }
                .padding(FMSpacing.xl)
            }
            .navigationTitle("Delete my account")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isDeleting)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .confirm2:
            confirmView
        case .reauthApple:
            reauthAppleView
        case .reauthPassword:
            reauthPasswordView
        case .idle, .confirm1, .done:
            EmptyView()
        }
    }

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: FMSpacing.lg) {
            VStack(alignment: .leading, spacing: FMSpacing.sm) {
                ForEach(Self.deletedItems, id: \.self) { item in
                    Text("•  \(item)")
                        .font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            destructiveButton(title: "Delete my account") {
                viewModel.confirmDelete(appState: appState)
            }
        }
    }

    /// Email password step only (shown after Firebase asks for a recent login).
    private var reauthBanner: some View {
        InfoBanner(systemImage: "lock", message: AuthError.requiresRecentLogin.userMessage)
    }

    private var reauthAppleView: some View {
        VStack(spacing: FMSpacing.lg) {
            // Apple re-auth is always shown (token revocation), so it gets its own §9.4 copy.
            InfoBanner(
                systemImage: "lock",
                title: "Sign in with Apple to confirm.",
                message: "Apple needs to confirm before we delete your account."
            )

            ZStack {
                SignInWithAppleButton(.continue) { request in
                    viewModel.prepareAppleRequest(request)
                } onCompletion: { result in
                    viewModel.handleAppleReauth(result, appState: appState)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: FMSize.buttonHeight)
                .opacity(viewModel.isDeleting ? 0.4 : 1)
                .disabled(viewModel.isDeleting)

                if viewModel.isDeleting {
                    ProgressView()
                }
            }
        }
    }

    private var reauthPasswordView: some View {
        VStack(spacing: FMSpacing.lg) {
            reauthBanner

            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { viewModel.deleteWithPassword(appState: appState) }
                .disabled(viewModel.isDeleting)

            PrimaryButton(title: "Confirm and delete", isLoading: viewModel.isDeleting) {
                viewModel.deleteWithPassword(appState: appState)
            }
            .disabled(viewModel.password.isEmpty)
            .opacity(viewModel.password.isEmpty ? 0.5 : 1)
        }
    }

    /// Filled red DestructiveButton (DESIGN-SPEC §4), used only for this final confirm.
    private func destructiveButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .opacity(viewModel.isDeleting ? 0 : 1)
                if viewModel.isDeleting {
                    ProgressView()
                        .tint(.white)
                }
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: FMSize.buttonHeight)
            .background(Color.fm.sosRed)
            .cornerRadius(FMRadius.card)
        }
        .disabled(viewModel.isDeleting)
    }
}
