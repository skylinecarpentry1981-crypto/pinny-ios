import SwiftUI

/// Circular photo via AsyncImage, falling back to initials.
/// Initials show while the photo loads and if it fails, so a row never goes blank. AsyncImage uses
/// the shared URLSession, whose URLCache keeps the JPEG for later appearances (STAGE-8-CONTRACT §3).
struct AvatarView: View {
    let name: String
    var photoURL: String? = nil
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let photoURL, let url = URL(string: photoURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        initials
                    @unknown default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(name)
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Color.fm.accent.opacity(0.18))
            Text(initialsText)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(Color.fm.accent)
        }
    }

    private var initialsText: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
