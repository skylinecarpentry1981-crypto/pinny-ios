import SwiftUI
import UIKit

/// The SOS Confirm sheet's button (DESIGN-SPEC §4, §13.3): hold 1.5 s to send. On touch down it
/// scales to 0.96 and a 4 pt white ring, inset 6 pt, fills clockwise from 12 o'clock; light haptics at
/// 0.5 s and 1.0 s, heavy at 1.5 s when it fires. Releasing early, or dragging more than 44 pt off
/// the button, runs the ring back to 0 in 0.2 s and sends nothing. Reduce Motion: no fill, the ring
/// jumps to full at 1.5 s. VoiceOver: the "Send SOS" action fires without a hold.
struct SOSHoldButton: View {
    /// True from touch down until release, cancel or fire. The sheet blocks swipe-to-dismiss meanwhile.
    @Binding var isHolding: Bool
    let onFire: () -> Void
    /// A hold that ended before 1.5 s; the sheet shows "Keep holding to send."
    let onEarlyRelease: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    /// A finger is down. Resets by itself when the touch ends or the system cancels it. Stays true
    /// after a drag-off cancel, so the same touch can't start a new hold.
    @GestureState private var isPressed = false
    @State private var holdTask: Task<Void, Never>?
    @State private var size: CGSize = .zero

    private static let holdDuration: Double = 1.5
    /// Haptic ticks at 0.5 s and 1.0 s, firing at 1.5 s.
    private static let tickNanoseconds: UInt64 = 500_000_000
    private static let dragTolerance: CGFloat = 44

    var body: some View {
        Label("Hold to send SOS", systemImage: "sos")
            .font(.headline.bold())
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, FMSpacing.xl)
            .padding(.vertical, FMSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Capsule().fill(Color.fm.sosRed))
            .overlay(
                CapsuleRing()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(6)
            )
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { size = $0 }
                }
            )
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        pressed = true
                    }
                    .onChanged { value in
                        if isHolding, isFarOutside(value.location) {
                            cancel()
                        }
                    }
            )
            .onChange(of: isPressed) { pressed in
                if pressed {
                    begin()
                } else if isHolding {
                    cancel()
                }
            }
            .scaleEffect(isHolding ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: isHolding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hold to send SOS")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Send SOS") {
                complete()
            }
            .onDisappear {
                holdTask?.cancel()
                holdTask = nil
            }
    }

    private func isFarOutside(_ point: CGPoint) -> Bool {
        point.x < -Self.dragTolerance || point.y < -Self.dragTolerance
            || point.x > size.width + Self.dragTolerance || point.y > size.height + Self.dragTolerance
    }

    private func begin() {
        isHolding = true
        if !reduceMotion {
            withAnimation(.linear(duration: Self.holdDuration)) {
                progress = 1
            }
        }
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            for tick in 1...3 {
                try? await Task.sleep(nanoseconds: Self.tickNanoseconds)
                guard !Task.isCancelled else { return }
                if tick < 3 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            complete()
        }
    }

    /// Early release or drag-off: nothing is sent. No haptic.
    private func cancel() {
        holdTask?.cancel()
        holdTask = nil
        isHolding = false
        if reduceMotion {
            progress = 0
        } else {
            withAnimation(.linear(duration: 0.2)) {
                progress = 0
            }
        }
        onEarlyRelease()
    }

    /// 1.5 s reached, or VoiceOver's Send SOS.
    private func complete() {
        holdTask?.cancel()
        holdTask = nil
        isHolding = false
        progress = 1
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        onFire()
    }
}

/// A capsule outline that starts at 12 o'clock (top centre) and runs clockwise, so `trim(from: 0, to:)`
/// fills it like a clock hand.
private struct CapsuleRing: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.midY),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.midY),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
