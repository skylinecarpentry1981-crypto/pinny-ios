import SwiftUI

struct MemberRow: View {
    let member: AppUser
    var isMe: Bool = false
    /// Trailing pin button: switch to the Map tab centred on this member. Disabled until they have a location.
    var onShowOnMap: (() -> Void)? = nil

    private var lastSeen: String {
        member.lastLocation?.statusText ?? "No location yet"
    }

    private var isStale: Bool {
        member.lastLocation?.isStale ?? false
    }

    var body: some View {
        HStack(spacing: FMSpacing.md) {
            AvatarView(name: member.name, photoURL: member.photoURL, size: 40)
                // Grey ring when stale (> 24 h); the subtitle also says "Last seen".
                .overlay(Circle().stroke(Color.fm.stale, lineWidth: 2).opacity(isStale ? 1 : 0))
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(member.name) (You)" : member.name)
                    .font(.body)
                Text(lastSeen)
                    .font(.caption)
                    .foregroundColor(Color.fm.textSecondary)
            }
            Spacer()
            if let onShowOnMap {
                Button(action: onShowOnMap) {
                    Image(systemName: "mappin.circle")
                        .font(.title2)
                        .frame(width: FMSize.minTapTarget, height: FMSize.minTapTarget)
                }
                // Borderless so only the icon (not the whole List row) triggers it.
                .buttonStyle(.borderless)
                .disabled(member.lastLocation == nil)
                .accessibilityLabel("Show \(member.name) on map")
            }
        }
        .padding(.vertical, FMSpacing.xs)
    }
}
