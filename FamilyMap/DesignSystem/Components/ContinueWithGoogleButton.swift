import SwiftUI

/// "Continue with Google" (DESIGN-SPEC §3.1): same frame and radius as PrimaryButton and the Apple
/// button. White fill in both modes with a grey hairline so it still reads on a white screen.
/// Contrast: label #1F1F1F on white 16.1:1; border #747775 on white 4.6:1 (≥ 3:1 non-text);
/// the "G" #4285F4 on white 3.6:1 is large bold text (≥ 3:1) and hidden from VoiceOver.
/// Not named GoogleSignInButton: GoogleSignInSwift has a type with that name.
struct ContinueWithGoogleButton: View {
    var isLoading: Bool = false
    let action: () -> Void

    private static let label = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
    private static let border = Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255)
    private static let googleBlue = Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255)

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: FMSpacing.sm) {
                    Text("G")
                        .font(.title3.bold())
                        .foregroundColor(Self.googleBlue)
                        .accessibilityHidden(true)
                    Text("Continue with Google")
                        .font(.headline)
                        .foregroundColor(Self.label)
                }
                .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(Self.label)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: FMSize.buttonHeight)
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: FMRadius.card)
                    .stroke(Self.border, lineWidth: 1)
            )
            .cornerRadius(FMRadius.card)
        }
        .disabled(isLoading)
    }
}
