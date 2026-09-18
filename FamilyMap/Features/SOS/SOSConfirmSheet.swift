import SwiftUI
import UIKit

/// The SOS send flow (DESIGN-SPEC §13.3): share one fix with `src: "sos"` (skipped when location is
/// off or no fix comes), then the SOS message. The message ID is made before the first write and
/// reused by Try again, so a timed-out send that landed is shown as Sent: one SOS, never two.
@MainActor
final class SOSFlow: ObservableObject {
    enum Phase: Equatable {
        case confirm
        case sharing
        case sending
        case sent(withLocation: Bool)
        /// Already the §13.3 failure string.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .confirm

    private var messageId: String?
    /// Guards against a second run while one is in flight (rapid double trigger).
    private var isRunning = false

    // The number follows the device region (EmergencyNumber): "000" in Australia, "911" in the US...
    static var offlineFailure: String {
        "Couldn't send SOS. Check your connection, or call \(EmergencyNumber.forCurrentRegion())."
    }
    static var otherFailure: String {
        "Couldn't send SOS. Try again, or call \(EmergencyNumber.forCurrentRegion())."
    }
    private static let sendTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// Swipe-to-dismiss is off while sharing or sending.
    var isBusy: Bool {
        phase == .sharing || phase == .sending
    }

    /// The hold fired (or VoiceOver's Send SOS). Ignored unless the sheet is still asking.
    func confirm(appState: AppState) {
        guard phase == .confirm else { return }
        run(appState: appState)
    }

    /// Try again: sends at once with the same message ID, no second hold (the user already confirmed).
    func retry(appState: AppState) {
        guard case .failed = phase else { return }
        run(appState: appState)
    }

    private func run(appState: AppState) {
        guard !isRunning else { return }
        guard let sender = appState.currentUser, let familyId = sender.familyId else {
            fail(Self.otherFailure)
            return
        }
        isRunning = true
        let chatService = appState.chatService
        let messageId = self.messageId ?? chatService.newMessageId(familyId: familyId)
        self.messageId = messageId
        Task { @MainActor in
            defer { isRunning = false }
            // Offline, nothing can reach the family: say so at once.
            guard appState.locationSync.isOnline else {
                fail(Self.offlineFailure)
                return
            }

            // 1. Location, when allowed: one fix (3 s, else a cached one ≤ 2 min old) written as
            //    lastLocation with src "sos". No fix or a failed write: carry on without it.
            //    A share already running (e.g. the app-open one) is taken over by `share(source: .sos)`.
            var withLocation = false
            if appState.locationService.isAuthorized {
                phase = .sharing
                withLocation = await appState.locationSync.share(source: .sos)
            }

            // 2. The SOS message.
            phase = .sending
            announce("Sending SOS")
            do {
                try await withTimeout(
                    nanoseconds: Self.sendTimeoutNanoseconds,
                    timeoutError: ChatError.timedOut
                ) {
                    try await chatService.sendSOS(familyId: familyId, sender: sender, messageId: messageId)
                }
                phase = .sent(withLocation: withLocation)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                announce("SOS sent to your family")
            } catch {
                fail(FamilyError.from(error) == .network ? Self.offlineFailure : Self.otherFailure)
            }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        announce(message)
    }

    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// SOS Confirm sheet (DESIGN-SPEC §3.8, §13.3), presented from the Map tab's SOS buttons.
/// Hold to confirm, then Sharing location → Sending → Sent (stays until Done) or Failed (Try again).
struct SOSConfirmSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationService: LocationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var flow = SOSFlow()
    @State private var isHolding = false
    @State private var showsKeepHolding = false
    @State private var keepHoldingTask: Task<Void, Never>?

    /// Emergency number for the device region (000 in Australia, 911 in the US, 112 elsewhere).
    /// Opens the system call confirmation.
    private var emergencyNumber: String { EmergencyNumber.forCurrentRegion() }
    private var emergencyCallURL: URL? { URL(string: "tel://\(emergencyNumber)") }

    var body: some View {
        content
            .padding(FMSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.fm.sosRed.opacity(0.08).ignoresSafeArea())
            // At accessibility text sizes the content needs the full height.
            .presentationDetents([dynamicTypeSize.isAccessibilitySize ? PresentationDetent.large : PresentationDetent.medium])
            .interactiveDismissDisabled(isHolding || flow.isBusy)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .confirm:
            confirmView
        case .sharing:
            progressView("Sharing your location…")
        case .sending:
            progressView("Sending SOS…")
        case .sent(let withLocation):
            sentView(withLocation: withLocation)
        case .failed(let message):
            failedView(message)
        }
    }

    // MARK: - States

    private var confirmView: some View {
        VStack(spacing: FMSpacing.lg) {
            Spacer(minLength: 0)
            Text("Send SOS to family?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(locationService.isAuthorized
                 ? "Everyone gets an alert with your current location."
                 : "Everyone gets an alert. Location is off, so it won't say where you are.")
                .font(.body)
                .foregroundColor(Color.fm.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)

            SOSHoldButton(
                isHolding: $isHolding,
                onFire: { flow.confirm(appState: appState) },
                onEarlyRelease: { showKeepHoldingHint() }
            )

            Text("Keep holding to send.")
                .font(.footnote)
                .foregroundColor(Color.fm.textSecondary)
                .opacity(showsKeepHolding ? 1 : 0)
                .accessibilityHidden(!showsKeepHolding)

            Button("Cancel") {
                dismiss()
            }
            .frame(minHeight: FMSize.minTapTarget)
            .disabled(isHolding)
        }
    }

    private func progressView(_ text: String) -> some View {
        VStack(spacing: FMSpacing.lg) {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.large)
            Text(text)
                .font(.headline)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func sentView(withLocation: Bool) -> some View {
        VStack(spacing: FMSpacing.lg) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(Color.fm.accent)
                .accessibilityHidden(true)
            Text("SOS sent to your family")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if !withLocation {
                Text("Sent without your location.")
                    .font(.body)
                    .foregroundColor(Color.fm.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            callButton
            PrimaryButton(title: "Done") {
                dismiss()
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: FMSpacing.lg) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(Color.fm.sosRedText)
                .accessibilityHidden(true)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PrimaryButton(title: "Try again") {
                flow.retry(appState: appState)
            }
            callButton
        }
    }

    private var callButton: some View {
        PrimaryButton(title: "Call \(emergencyNumber)", style: .bordered) {
            callEmergency()
        }
        .accessibilityLabel("Call emergency services, \(emergencyNumber)")
    }

    // MARK: - Actions

    /// "Keep holding to send." under the button for 2 s after an early release. No haptic.
    private func showKeepHoldingHint() {
        keepHoldingTask?.cancel()
        showsKeepHolding = true
        keepHoldingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            showsKeepHolding = false
        }
    }

    private func callEmergency() {
        guard let url = emergencyCallURL else { return }
        UIApplication.shared.open(url)
    }
}
