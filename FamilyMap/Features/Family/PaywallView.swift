import SwiftUI
import UIKit

/// Family Pass paywall (STAGE-7-CONTRACT §4, DESIGN-SPEC §14). A `.large` sheet, presented from
/// onboarding ("Create family" without a pass) and from Settings › Family Pass.
/// Success is the server's word: the view flips to "You're all set" when `users/{uid}.pass` arrives.
struct PaywallView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var passService: PassService
    @Environment(\.dismiss) private var dismiss
    @State private var isRestoring = false

    /// Onboarding only: closes the sheet and moves to the invite-code field. Nil hides the link.
    var onJoinInstead: (() -> Void)? = nil
    /// Success "Continue": the presenter carries on (onboarding creates the family). Nil = "Done".
    var onContinue: (() -> Void)? = nil

    private struct Benefit: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
    }

    private static let benefits = [
        Benefit(icon: "person.3.fill", text: "Create your family and share one invite code"),
        Benefit(icon: "person.badge.plus", text: "Everyone joins free, as many as you like"),
        Benefit(icon: "map.fill", text: "Map, chat, SOS and places for the whole family")
    ]

    private var hasPass: Bool { appState.currentUser?.hasPass ?? false }
    /// The server accepted the purchase; the users/{uid} listener has not delivered `pass` yet.
    private var isAwaitingServer: Bool { passService.didRedeem && !hasPass }
    /// UI locked: purchasing, verifying, loading, or the moment between redeem and the listener.
    private var isLocked: Bool { passService.isBusy || isAwaitingServer }
    private var isVerifying: Bool { passService.state == .verifying || isAwaitingServer }

    private var price: String? { passService.product?.displayPrice }

    private var buyTitle: String {
        if let price { return "Buy Family Pass — \(price)" }
        return "Buy Family Pass"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: FMSpacing.xl) {
                header
                benefits
                if hasPass {
                    successActions
                } else {
                    purchaseActions
                }
                Text("One-time purchase, tied to your Apple ID.")
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, FMSpacing.xl)
            .padding(.top, FMSpacing.xxl)
            .padding(.bottom, FMSpacing.xl)
        }
        .background(Color.fm.background)
        .overlay(alignment: .topTrailing) { closeButton }
        .interactiveDismissDisabled(isLocked)
        .task {
            passService.reset()
            await passService.loadProducts()
        }
        .onChange(of: hasPass) { confirmed in
            guard confirmed else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: "You're all set")
        }
        .onDisappear { passService.reset() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: FMSpacing.md) {
            Image("PinnyMascot")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 120)
                .accessibilityHidden(true)
            if hasPass {
                Label {
                    Text("You're all set")
                } icon: {
                    Image(systemName: "checkmark")
                        .foregroundColor(Color.fm.accent)
                }
                .font(.largeTitle.bold())
            } else {
                Text("Family Pass")
                    .font(.largeTitle.bold())
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: FMSpacing.md) {
            ForEach(Self.benefits) { benefit in
                HStack(alignment: .firstTextBaseline, spacing: FMSpacing.md) {
                    Image(systemName: benefit.icon)
                        .font(.body.weight(.semibold))
                        .foregroundColor(Color.fm.accent)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(benefit.text)
                        .font(.body)
                        .foregroundColor(Color.fm.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(FMSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fm.surface)
        .cornerRadius(FMRadius.card)
    }

    @ViewBuilder
    private var purchaseActions: some View {
        VStack(spacing: FMSpacing.md) {
            if case .failed(let message) = passService.state {
                ErrorBanner(message: message)
            }

            if passService.state == .pending {
                InfoBanner(
                    systemImage: "hourglass",
                    title: "Waiting for approval",
                    message: "Ask to Buy is on. Once it's approved, your Family Pass turns on here."
                )
                .accessibilityElement(children: .combine)
            } else if passService.product == nil, passService.state != .loading {
                // Products failed to load: the banner above says why.
                PrimaryButton(title: "Try again") {
                    Task { await passService.loadProducts() }
                }
            } else {
                PrimaryButton(title: buyTitle, isLoading: isLocked) {
                    Task { await passService.purchase() }
                }
                .accessibilityLabel(price.map { "Buy Family Pass for \($0)" } ?? "Buy Family Pass")
                .accessibilityHint("Opens the App Store payment sheet")
            }

            if isVerifying, !isRestoring {
                Text("Confirming your purchase…")
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
            }

            Button {
                restore()
            } label: {
                HStack(spacing: FMSpacing.sm) {
                    Text("Restore purchases")
                    if isRestoring {
                        ProgressView()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: FMSize.minTapTarget)
            }
            .disabled(isLocked)
            .accessibilityHint("Finds a Family Pass already bought with this Apple ID")

            if let onJoinInstead {
                Button("Join with a code instead", action: onJoinInstead)
                    .font(.subheadline)
                    .foregroundColor(Color.fm.textSecondary)
                    .frame(minHeight: FMSize.minTapTarget)
                    .disabled(isLocked)
            }
        }
    }

    private var successActions: some View {
        PrimaryButton(title: onContinue == nil ? "Done" : "Continue") {
            if let onContinue {
                onContinue()
            } else {
                dismiss()
            }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(Color.fm.textSecondary)
                .frame(width: FMSize.minTapTarget, height: FMSize.minTapTarget)
        }
        .accessibilityLabel("Close")
        .disabled(isLocked)
        .padding(FMSpacing.sm)
    }

    // MARK: - Actions

    private func restore() {
        guard !isRestoring, !isLocked else { return }
        isRestoring = true
        Task { @MainActor in
            defer { isRestoring = false }
            await passService.restore()
        }
    }
}
