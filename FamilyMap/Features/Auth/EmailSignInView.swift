import SwiftUI

struct EmailSignInView: View {
    private enum Mode {
        case signIn
        case createAccount
    }

    @EnvironmentObject private var appState: AppState
    @State private var mode: Mode = .signIn
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespaces)
    }

    /// Enabled on non-empty fields only; format checks run in `submit()` so their §9.1 strings can show.
    private var canSubmit: Bool {
        let nameOK = mode == .signIn || !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        return !trimmedEmail.isEmpty && !password.isEmpty && nameOK
    }

    private var emailLooksValid: Bool {
        let parts = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    var body: some View {
        VStack(spacing: FMSpacing.lg) {
            if mode == .createAccount {
                TextField("Your name", text: $displayName)
                    .textContentType(.name)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)

            PrimaryButton(title: mode == .signIn ? "Sign in" : "Create account", isLoading: isBusy) {
                submit()
            }
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            if let infoMessage {
                InfoBanner(systemImage: "envelope", message: infoMessage)
            }

            Button(mode == .signIn ? "New here? Create an account" : "Have an account? Sign in") {
                errorMessage = nil
                infoMessage = nil
                mode = mode == .signIn ? .createAccount : .signIn
            }
            .font(.footnote)
            .foregroundColor(Color.fm.textSecondary)
            .frame(minHeight: FMSize.minTapTarget)
            .disabled(isBusy)

            if mode == .signIn {
                Button("Forgot password?") {
                    resetPassword()
                }
                .font(.footnote)
                .foregroundColor(Color.fm.textSecondary)
                .frame(minHeight: FMSize.minTapTarget)
                .disabled(isBusy)
            }

            Spacer()
        }
        .padding(FMSpacing.xl)
        .navigationTitle(mode == .signIn ? "Email sign in" : "Create account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() {
        guard canSubmit, !isBusy else { return }
        errorMessage = nil
        infoMessage = nil
        guard emailLooksValid else {
            errorMessage = AuthError.invalidEmail.userMessage
            return
        }
        if mode == .createAccount, password.count < 6 {
            errorMessage = AuthError.weakPassword.userMessage
            return
        }
        isBusy = true
        let emailToUse = trimmedEmail
        // Rules count UTF-16 units (an emoji counts 2+).
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces).clamped(toUTF16: 40)
        Task { @MainActor in
            defer { isBusy = false }
            do {
                switch mode {
                case .signIn:
                    try await appState.authService.signIn(email: emailToUse, password: password)
                case .createAccount:
                    try await appState.authService.createAccount(
                        email: emailToUse,
                        password: password,
                        displayName: trimmedName
                    )
                }
            } catch {
                errorMessage = error.userMessage
                // One tap to recover: keep the fields and switch to Create account.
                if mode == .signIn, (error as? AuthError) == .userNotFound {
                    mode = .createAccount
                }
            }
        }
    }

    private func resetPassword() {
        guard !isBusy else { return }
        errorMessage = nil
        infoMessage = nil
        guard emailLooksValid else {
            errorMessage = AuthError.invalidEmail.userMessage
            return
        }
        isBusy = true
        let emailToUse = trimmedEmail
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await appState.authService.sendPasswordReset(email: emailToUse)
                infoMessage = "Reset link sent to \(emailToUse)"
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
