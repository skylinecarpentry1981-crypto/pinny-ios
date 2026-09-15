import SwiftUI
import UIKit

/// Big monospaced invite code with Copy + Share (ShareLink, iOS 16).
struct InviteCodeCard: View {
    let code: String
    @State private var copied = false

    static func shareText(for code: String) -> String {
        "Join our family on Pinny with code \(code)"
    }

    /// "Invite code, A, B, C, 1, 2, 3" so VoiceOver reads one character at a time.
    private var spokenCode: String {
        (["Invite code"] + code.map { String($0) }).joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: FMSpacing.md) {
            Text(code)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .kerning(4)
                .accessibilityLabel(spokenCode)

            HStack(spacing: FMSpacing.md) {
                Button {
                    UIPasteboard.general.string = code
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(notification: .announcement, argument: "Copied")
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: FMSize.minTapTarget, minHeight: FMSize.minTapTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Copy invite code")

                ShareLink(item: Self.shareText(for: code)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(minWidth: FMSize.minTapTarget, minHeight: FMSize.minTapTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Share invite code")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FMSpacing.sm)
    }
}
