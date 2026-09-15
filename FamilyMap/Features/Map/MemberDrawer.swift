import SwiftUI
import UIKit

/// Snap points of the Map tab's member drawer (DESIGN-SPEC 11.2).
enum DrawerSnap: CaseIterable {
    case collapsed
    case half
    case full

    var accessibilityValue: String {
        switch self {
        case .collapsed: return "Collapsed"
        case .half: return "Half"
        case .full: return "Full"
        }
    }
}

enum DrawerMetrics {
    /// Handle zone 20 + header 44 + one 64 pt row.
    static let collapsedHeight: CGFloat = 128
    static let halfFraction: CGFloat = 0.45
    /// In full, the drawer's top edge sits this far below the safe-area top, so the pill row stays on the map.
    static let fullTopGap: CGFloat = 56
    static let handleZone: CGFloat = 20
    static let headerHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 20
    /// A flick: SwiftUI's projected end of the drag lies this far past the release point, which is
    /// roughly the spec's 500 pt/s. Tune on device.
    static let flickDistance: CGFloat = 80

    /// Spring per spec; Reduce Motion -> short ease, no bounce.
    static func snapAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// `available` = safe-area top to tab-bar top.
    static func height(for snap: DrawerSnap, available: CGFloat) -> CGFloat {
        switch snap {
        case .collapsed: return collapsedHeight
        case .half: return max(collapsedHeight, available * halfFraction)
        case .full: return max(collapsedHeight, available - fullTopGap)
        }
    }
}

/// Asks the drawer to scroll a row into view. The token makes a repeat request for the same row a new value.
struct DrawerScrollRequest: Equatable {
    let rowId: String
    let token = UUID()
}

/// A custom in-view panel resting on the tab bar (not a system sheet, so the tab bar stays visible and
/// the map stays pannable above it). Drag the handle or header; when collapsed, drag anywhere.
/// Tap the handle to cycle collapsed -> half -> full -> collapsed.
struct MemberDrawer<Header: View, Content: View>: View {
    @Binding var snap: DrawerSnap
    /// Live finger offset (down = positive) while dragging; 0 when settled.
    @Binding var dragTranslation: CGFloat
    let available: CGFloat
    /// Row to scroll into view (pin tap / Family-tab focus).
    let scrollRequest: DrawerScrollRequest?
    let header: Header
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        snap: Binding<DrawerSnap>,
        dragTranslation: Binding<CGFloat>,
        available: CGFloat,
        scrollRequest: DrawerScrollRequest?,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self._snap = snap
        self._dragTranslation = dragTranslation
        self.available = available
        self.scrollRequest = scrollRequest
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: DrawerMetrics.handleZone)
                header
                    .frame(height: DrawerMetrics.headerHeight)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .overlay(alignment: .top) { handle }

            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .padding(.bottom, FMSpacing.lg)
                }
                // Collapsed: the list does not scroll, so a drag anywhere moves the drawer.
                .scrollDisabled(snap == .collapsed)
                .gesture(dragGesture, including: snap == .collapsed ? .all : .subviews)
                .onChange(of: scrollRequest) { request in
                    guard let request else { return }
                    withAnimation(DrawerMetrics.snapAnimation(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(request.rowId, anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(drawerBackground, in: TopRoundedRectangle(radius: DrawerMetrics.cornerRadius))
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: -2)
        .onChange(of: snap) { _ in
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    private var drawerBackground: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color.fm.background) : AnyShapeStyle(.regularMaterial)
    }

    /// 36 x 5 capsule in a 120 x 44 tap area. VoiceOver: "Family list", adjustable.
    private var handle: some View {
        Capsule()
            .fill(Color(uiColor: .tertiaryLabel))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .frame(width: 120, height: FMSize.minTapTarget, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { cycle() }
            .gesture(dragGesture)
            .accessibilityElement()
            .accessibilityLabel("Family list")
            .accessibilityValue(snap.accessibilityValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { cycle() }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(to: next(after: snap, taller: true))
                case .decrement: move(to: next(after: snap, taller: false))
                @unknown default: break
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                let settled = DrawerMetrics.height(for: snap, available: available)
                let released = settled - value.translation.height
                let projected = settled - value.predictedEndTranslation.height
                let target = snapTarget(releasedHeight: released, projectedHeight: projected)
                withAnimation(DrawerMetrics.snapAnimation(reduceMotion: reduceMotion)) {
                    snap = target
                    dragTranslation = 0
                }
            }
    }

    /// Nearest snap to the release point, or the next one in the flick direction when the projected
    /// end (`predictedEndTranslation`) lies more than `flickDistance` beyond it.
    private func snapTarget(releasedHeight: CGFloat, projectedHeight: CGFloat) -> DrawerSnap {
        let heights = DrawerSnap.allCases.map { ($0, DrawerMetrics.height(for: $0, available: available)) }
        let momentum = projectedHeight - releasedHeight
        if momentum > DrawerMetrics.flickDistance {
            return heights.first { $0.1 > releasedHeight + 1 }?.0 ?? .full
        }
        if momentum < -DrawerMetrics.flickDistance {
            return heights.last { $0.1 < releasedHeight - 1 }?.0 ?? .collapsed
        }
        let nearest = heights.min { abs($0.1 - releasedHeight) < abs($1.1 - releasedHeight) }
        return nearest?.0 ?? snap
    }

    private func cycle() {
        switch snap {
        case .collapsed: move(to: .half)
        case .half: move(to: .full)
        case .full: move(to: .collapsed)
        }
    }

    private func next(after snap: DrawerSnap, taller: Bool) -> DrawerSnap {
        switch (snap, taller) {
        case (.collapsed, true): return .half
        case (.half, true), (.full, true): return .full
        case (.full, false): return .half
        case (.half, false), (.collapsed, false): return .collapsed
        }
    }

    private func move(to target: DrawerSnap) {
        withAnimation(DrawerMetrics.snapAnimation(reduceMotion: reduceMotion)) {
            snap = target
        }
    }
}

/// Rectangle with only the top corners rounded (iOS 16 has no UnevenRoundedRectangle).
struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
