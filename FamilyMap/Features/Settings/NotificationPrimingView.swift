import SwiftUI

/// Soft ask before the system notification prompt (DESIGN-SPEC §3.9, §13.1). Shown once, as a
/// medium-detent sheet; "Not now" or a swipe down is final (the Settings row is the only re-offer).
struct NotificationPrimingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: FMSpacing.lg) {
            Spacer(minLength: FMSpacing.md)

            Image(systemName: "bell.badge")
                .font(.system(size: 64))
                .foregroundColor(Color.fm.accent)
                .accessibilityHidden(true)

            Text("Stay in the loop")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text("Get a heads-up when a family member checks in, and always for SOS alerts. You can change this any time in Settings.")
                .font(.body)
                .foregroundColor(Color.fm.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: FMSpacing.md)

            PrimaryButton(title: "Turn on notifications", isLoading: isRequesting) {
                requestPermission()
            }

            Button("Not now") {
                dismiss()
            }
            .font(.footnote)
            .foregroundColor(Color.fm.textSecondary)
            .frame(minHeight: FMSize.minTapTarget)
            .disabled(isRequesting)
        }
        .padding(FMSpacing.xl)
        .presentationDetents([.medium])
    }

    /// Dismisses on any answer. A failed registration stays silent; the Settings rows show the state.
    private func requestPermission() {
        guard !isRequesting else { return }
        isRequesting = true
        Task { @MainActor in
            await appState.requestNotificationPermission()
            isRequesting = false
            dismiss()
        }
    }
}
