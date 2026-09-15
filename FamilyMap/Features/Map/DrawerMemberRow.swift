import SwiftUI

/// One member in the Map drawer (DESIGN-SPEC 11.4): avatar, name, place line, time line, battery.
/// Tapping selects the member; the selected row expands inline with its actions.
struct DrawerMemberRow: View {
    let member: AppUser
    let isMe: Bool
    let place: PlaceNameResolver.PlaceName
    let isExpanded: Bool
    /// Disables Check in while any share is in flight.
    let isSharing: Bool
    let onTap: () -> Void
    let onOpenInMaps: () -> Void
    let onMessage: () -> Void
    let onCheckIn: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var point: LocationPoint? { member.lastLocation }
    /// Other members without a location are greyed and only offer Message.
    private var isGreyed: Bool { !isMe && point == nil }
    private var name: String { isMe ? "You" : member.name }

    private var ringColor: Color {
        guard let point else { return .clear }
        if point.isStale { return Color.fm.stale }
        return isMe ? Color.fm.accent : Color.white
    }

    /// "Mum, near George St Parramatta, updated 12 min ago, battery 40 percent, charging".
    private var accessibilityText: String {
        guard let point else { return "\(name), no location yet" }
        var parts = [name, place.spoken]
        parts.append("\(point.isStale ? "last seen" : "updated") \(point.displayDate.relativePhrase)")
        if let battery = point.battery {
            parts.append("battery \(battery) percent")
            if point.charging == true { parts.append("charging") }
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                summary
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(point == nil ? "Double-tap to show actions" : "Double-tap to show on map")
            .modifier(RowAccessibilityActions(
                isMe: isMe,
                isLocated: point != nil,
                onOpenInMaps: onOpenInMaps,
                onMessage: onMessage,
                onCheckIn: onCheckIn
            ))

            if isExpanded {
                actions
                    .padding(.leading, 72)
                    .padding(.trailing, FMSpacing.lg)
                    .padding(.bottom, FMSpacing.sm)
                    .transition(.opacity)
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: FMSpacing.lg) {
            AvatarView(name: member.name, photoURL: member.photoURL, size: 40)
                .padding(2)
                .background(Circle().fill(ringColor))
                .opacity(point?.isStale == true ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: FMSpacing.sm)
                    if let point, let battery = point.battery {
                        BatteryIndicator(level: battery, charging: point.charging == true)
                    }
                }
                Text(place.display)
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if let point {
                    Text(point.statusText)
                        .font(.caption)
                        .foregroundColor(Color.fm.textSecondary)
                }
            }
        }
        .padding(.horizontal, FMSpacing.lg)
        .padding(.vertical, FMSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .opacity(isGreyed ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var actions: some View {
        if isMe {
            Button("Check in", action: onCheckIn)
                .buttonStyle(.bordered)
                .frame(minHeight: FMSize.minTapTarget)
                .disabled(isSharing)
        } else {
            HStack(spacing: FMSpacing.sm) {
                if point != nil {
                    Button("Open in Maps", action: onOpenInMaps)
                        .buttonStyle(.bordered)
                        .frame(minHeight: FMSize.minTapTarget)
                }
                Button("Message", action: onMessage)
                    .buttonStyle(.bordered)
                    .frame(minHeight: FMSize.minTapTarget)
            }
        }
    }
}

/// The expanded actions, also offered as VoiceOver custom actions on the row.
private struct RowAccessibilityActions: ViewModifier {
    let isMe: Bool
    let isLocated: Bool
    let onOpenInMaps: () -> Void
    let onMessage: () -> Void
    let onCheckIn: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isMe {
            content.accessibilityAction(named: "Check in", onCheckIn)
        } else if isLocated {
            content
                .accessibilityAction(named: "Open in Maps", onOpenInMaps)
                .accessibilityAction(named: "Message", onMessage)
        } else {
            content.accessibilityAction(named: "Message", onMessage)
        }
    }
}

/// Battery captured at share time: SF battery symbol + "40%", red at 15 % or below, bolt when charging.
struct BatteryIndicator: View {
    let level: Int
    let charging: Bool

    private var symbol: String {
        if charging { return "battery.100.bolt" }
        switch level {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private var tint: Color {
        level <= 15 ? Color.fm.sosRedText : Color.fm.textSecondary
    }

    var body: some View {
        HStack(spacing: FMSpacing.xs) {
            Image(systemName: symbol)
            Text("\(level)%")
                .font(.caption.monospacedDigit())
        }
        .font(.caption)
        .foregroundColor(tint)
        .accessibilityHidden(true)
    }
}

/// Only-me family (DESIGN-SPEC 11.5): shown under my row.
struct InviteRow: View {
    let inviteCode: String

    var body: some View {
        HStack(spacing: FMSpacing.lg) {
            Image(systemName: "person.badge.plus")
                .foregroundColor(Color.fm.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Invite your family")
                    .font(.body.weight(.semibold))
                Text("It's just you for now.")
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
            }
            Spacer(minLength: FMSpacing.sm)
            ShareLink(item: InviteCodeCard.shareText(for: inviteCode)) {
                Text("Share")
                    .frame(minHeight: FMSize.minTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Share invite code")
        }
        .padding(.horizontal, FMSpacing.lg)
        .padding(.vertical, FMSpacing.md)
        .frame(minHeight: 64)
    }
}
