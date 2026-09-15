import SwiftUI
import UIKit

/// One bubble in a group (DESIGN-SPEC §13.4). Mine: right, accent. Others: left, grey, first name
/// above the first bubble of a group, avatar beside the last.
struct MessageBubble: View {
    struct Avatar {
        let name: String
        let photoURL: String?
        /// The sender has left the family: initials in grey.
        let isFormerMember: Bool
    }

    let bubble: ChatViewModel.Bubble
    /// Nil for my bubbles.
    let avatar: Avatar?
    /// This bubble's own time ("Just now", "3:41 pm"); shown under the last of a group, read on every bubble.
    let time: String
    let maxBubbleWidth: CGFloat
    let onRetry: () -> Void
    let onDelete: () -> Void

    private static let avatarSize: CGFloat = 32
    private var message: ChatMessage { bubble.message }
    private var isMine: Bool { bubble.isMine }
    private var isFailed: Bool { bubble.delivery == .failed }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: FMSpacing.xs) {
            if !isMine && bubble.isFirstInGroup {
                Text(message.senderFirstName)
                    .font(.caption)
                    .foregroundColor(Color.fm.textSecondary)
                    .padding(.leading, Self.avatarSize + FMSpacing.sm + FMSpacing.xs)
            }

            // No Spacer here: an HStack would offer the bubble only half the row. The outer frame aligns it.
            HStack(alignment: .bottom, spacing: FMSpacing.sm) {
                if !isMine {
                    avatarColumn
                }

                HStack(alignment: .center, spacing: FMSpacing.sm) {
                    if isFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(Color.fm.sosRedText)
                    }
                    bubbleBody
                        .contextMenu { menuItems }
                }
                .frame(maxWidth: maxBubbleWidth, alignment: isMine ? .trailing : .leading)
            }

            statusLine
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(.top, bubble.isFirstInGroup ? FMSpacing.md : 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isFailed {
                onRetry()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isFailed ? "Double-tap to retry" : "")
        .accessibilityAddTraits(isFailed ? .isButton : [])
        .accessibilityAction {
            if isFailed {
                onRetry()
            }
        }
        .accessibilityActions { menuItems }
    }

    private var bubbleBody: some View {
        Text(message.text)
            .font(.body)
            .foregroundColor(isMine ? Color.fm.onAccent : Color.fm.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                BubbleShape(tailOnRight: isMine, hasTail: bubble.isLastInGroup)
                    .fill(isMine ? Color.fm.accent : Color(uiColor: .secondarySystemFill))
            )
            .opacity(bubble.delivery == .sending ? 0.6 : 1)
    }

    @ViewBuilder
    private var avatarColumn: some View {
        if bubble.isLastInGroup, let avatar {
            AvatarView(name: avatar.name, photoURL: avatar.photoURL, size: Self.avatarSize)
                .saturation(avatar.isFormerMember ? 0 : 1)
                .opacity(avatar.isFormerMember ? 0.6 : 1)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: Self.avatarSize, height: 1)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch bubble.delivery {
        case .sending:
            Text("Sending…")
                .font(.caption2)
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        case .failed:
            Text("Not sent. Tap to retry.")
                .font(.caption2)
                .foregroundColor(Color.fm.sosRedText)
        case .sent:
            if bubble.isLastInGroup {
                Text(time)
                    .font(.caption2)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
                    .padding(.leading, isMine ? 0 : Self.avatarSize + FMSpacing.sm + FMSpacing.xs)
            }
        }
    }

    /// Long-press menu and VoiceOver custom actions: Copy when sent; Retry and Delete when failed.
    @ViewBuilder
    private var menuItems: some View {
        switch bubble.delivery {
        case .sent:
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        case .failed:
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        case .sending:
            EmptyView()
        }
    }

    /// §13.6: "Mum, Home by 6?, 3:12 pm"; mine "You, …"; plus ", sending" / ", not sent".
    private var accessibilityText: String {
        let name = isMine ? "You" : message.senderFirstName
        var text = "\(name), \(message.text), \(time)"
        switch bubble.delivery {
        case .sending: text += ", sending"
        case .failed: text += ", not sent"
        case .sent: break
        }
        return text
    }
}

/// Radius 18 on every corner except the tail corner (2) on the last bubble of a group.
/// A custom shape because `UnevenRoundedRectangle` is iOS 17.
struct BubbleShape: Shape {
    let tailOnRight: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(18, rect.height / 2, rect.width / 2)
        let tail = hasTail ? min(2, radius) : radius
        let topLeft = radius
        let topRight = radius
        let bottomRight = tailOnRight ? tail : radius
        let bottomLeft = tailOnRight ? radius : tail

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
            radius: bottomRight,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
            radius: bottomLeft,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
