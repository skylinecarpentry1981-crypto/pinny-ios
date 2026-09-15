import SwiftUI

/// Map annotation: avatar in a 2 pt ring with the first name underneath. Tapping selects the member's
/// drawer row. Ring: white, accent for me, grey for stale (> 24 h, drawn at 50 % opacity).
/// The selected pin is scaled 1.2 (MapView also draws it last, on top).
struct MemberPinView: View {
    let member: AppUser
    let point: LocationPoint
    let isMe: Bool
    let isSelected: Bool
    let onTap: () -> Void

    private var ringColor: Color {
        if point.isStale { return Color.fm.stale }
        return isMe ? Color.fm.accent : Color.white
    }

    /// "Mum, updated 12 min ago" / "You, updated just now" / "Sol, last seen 3 days ago".
    private var accessibilityText: String {
        let who = isMe ? "You" : member.name
        let verb = point.isStale ? "last seen" : "updated"
        return "\(who), \(verb) \(point.displayDate.relativePhrase)"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                AvatarView(name: member.name, photoURL: member.photoURL, size: 40)
                    .padding(2)
                    .background(Circle().fill(ringColor))
                    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                Text(member.firstName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Color.fm.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: 80)
                    .background(.thinMaterial, in: Capsule())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(point.isStale ? 0.5 : 1)
            .scaleEffect(isSelected ? 1.2 : 1)
            .frame(minWidth: FMSize.minTapTarget, minHeight: FMSize.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Double-tap to show in family list")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
