import SwiftUI

@MainActor
final class FamilyOnboardingViewModel: ObservableObject {
    @Published var familyName = ""
    @Published var inviteCode = ""
    @Published var isBusy = false
    @Published var errorMessage: String?
    /// Set after a successful create; the view shows the invite code until "Continue".
    @Published var createdFamily: Family?

    var trimmedFamilyName: String {
        familyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canJoin: Bool {
        InviteCode.isValid(InviteCode.normalize(inviteCode)) && !isBusy
    }

    /// Keeps the code field uppercase and capped at 6 characters as the user types.
    func sanitizeInviteCode(_ raw: String) {
        let normalized = String(InviteCode.normalize(raw).prefix(InviteCode.length))
        if normalized != inviteCode {
            inviteCode = normalized
        }
    }

    /// Rules: validName is 1–40 UTF-16 units (an emoji counts 2+). Shows the §9.1 string instead of
    /// silently disabling. Checked before the paywall too, so nobody buys a pass for an empty name.
    func validatedFamilyName() -> String? {
        let name = trimmedFamilyName
        guard (1...40).contains(name.utf16.count) else {
            errorMessage = AppError.familyName
            return nil
        }
        return name
    }

    func createFamily(appState: AppState) async {
        guard !isBusy, let name = validatedFamilyName() else { return }
        await run {
            let family = try await appState.familyService.createFamily(name: name)
            appState.didCreate(family)
            createdFamily = family
        }
    }

    func joinFamily(appState: AppState) async {
        let code = InviteCode.normalize(inviteCode)
        guard InviteCode.isValid(code) else {
            errorMessage = AppError.malformedCode
            return
        }
        await run {
            let family = try await appState.familyService.joinFamily(code: code)
            appState.didJoin(family)
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            errorMessage = error.userMessage
        }
    }
}

struct FamilyOnboardingView: View {
    private enum Field: Hashable {
        case name
        case code
    }

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = FamilyOnboardingViewModel()
    @FocusState private var focusedField: Field?
    /// Family Pass gate (STAGE-7-CONTRACT §2): "Create family" without a pass opens the paywall.
    @State private var showPaywall = false
    /// What to do once the paywall sheet has closed.
    @State private var afterPaywall: AfterPaywall?

    private enum AfterPaywall {
        /// The server confirmed the pass and the user tapped Continue: create the family now.
        case create
        /// "Join with a code instead".
        case focusCode
    }

    /// Exactly one of the two buttons is filled: whichever field has focus or content.
    private var createIsPrimary: Bool {
        if focusedField == .code { return false }
        if focusedField == .name { return true }
        return viewModel.inviteCode.isEmpty
    }

    var body: some View {
        ScrollView {
            if let family = viewModel.createdFamily {
                successView(family: family)
            } else {
                setupView
            }
        }
        .background(Color.fm.background)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showPaywall, onDismiss: handlePaywallDismissed) {
            PaywallView(
                onJoinInstead: {
                    afterPaywall = .focusCode
                    showPaywall = false
                },
                onContinue: {
                    afterPaywall = .create
                    showPaywall = false
                }
            )
            .environmentObject(appState)
            .environmentObject(appState.passService)
            .presentationDetents([.large])
        }
    }

    /// Create: with a server-confirmed pass, straight to the family; without one, the paywall
    /// (after the name check, so the purchase never ends on a validation error).
    private func createTapped() {
        guard !viewModel.isBusy else { return }
        if appState.currentUser?.hasPass == true {
            Task { await viewModel.createFamily(appState: appState) }
            return
        }
        guard viewModel.validatedFamilyName() != nil else { return }
        viewModel.errorMessage = nil
        focusedField = nil
        showPaywall = true
    }

    private func handlePaywallDismissed() {
        let next = afterPaywall
        afterPaywall = nil
        switch next {
        case .create?:
            // `pass` came from the users/{uid} listener, so the rules' pass check will hold.
            guard appState.currentUser?.hasPass == true else { return }
            Task { await viewModel.createFamily(appState: appState) }
        case .focusCode?:
            focusedField = .code
        case nil:
            break
        }
    }

    private var setupView: some View {
        VStack(spacing: FMSpacing.xl) {
            VStack(spacing: FMSpacing.sm) {
                Text("Set up your family")
                    .font(.largeTitle.bold())
                Text("One family per account.")
                    .font(.subheadline)
                    .foregroundColor(Color.fm.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, FMSpacing.xxl)

            card(title: "Create a family") {
                TextField("Family name", text: $viewModel.familyName)
                    .textContentType(.organizationName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.go)
                    .onSubmit { createTapped() }
                PrimaryButton(
                    title: "Create family",
                    isLoading: viewModel.isBusy && createIsPrimary,
                    style: createIsPrimary ? .filled : .bordered
                ) {
                    createTapped()
                }
                .disabled(viewModel.isBusy)
            }

            card(title: "Join a family") {
                // Sanitised in the binding's setter. Rewriting the text from `.onChange` made iOS drop
                // keystrokes on device (only characters that needed no rewrite were accepted).
                TextField("Invite code", text: Binding(
                    get: { viewModel.inviteCode },
                    set: { viewModel.inviteCode = InviteCode.sanitizeTyped($0) }
                ))
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .font(.system(.title3, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .code)
                    .submitLabel(.join)
                    .onSubmit { Task { await viewModel.joinFamily(appState: appState) } }
                PrimaryButton(
                    title: "Join family",
                    isLoading: viewModel.isBusy && !createIsPrimary,
                    style: createIsPrimary ? .bordered : .filled
                ) {
                    Task { await viewModel.joinFamily(appState: appState) }
                }
                .disabled(!viewModel.canJoin)
                .opacity(viewModel.canJoin ? 1 : 0.5)
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            Button("Sign out") {
                appState.signOut()
            }
            .font(.footnote)
            .foregroundColor(Color.fm.textSecondary)
            .frame(minHeight: FMSize.minTapTarget)
            .disabled(viewModel.isBusy)
        }
        .padding(.horizontal, FMSpacing.xl)
        .padding(.bottom, FMSpacing.xl)
    }

    private func successView(family: Family) -> some View {
        VStack(spacing: FMSpacing.xl) {
            VStack(spacing: FMSpacing.sm) {
                Label {
                    Text("Family created")
                } icon: {
                    Image(systemName: "checkmark")
                        .foregroundColor(Color.fm.accent)
                }
                .font(.title2.bold())
                Text("Share this code with your family. They enter it under Join a family.")
                    .font(.subheadline)
                    .foregroundColor(Color.fm.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, FMSpacing.xxl)

            InviteCodeCard(code: family.inviteCode)
                .padding(FMSpacing.lg)
                .background(Color.fm.surface)
                .cornerRadius(FMRadius.card)

            PrimaryButton(title: "Continue to map") {
                appState.continueAfterCreate()
            }
        }
        .padding(.horizontal, FMSpacing.xl)
        .padding(.bottom, FMSpacing.xl)
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FMSpacing.md) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(FMSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fm.surface)
        .cornerRadius(FMRadius.card)
    }
}
