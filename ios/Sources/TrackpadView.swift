import SwiftUI
import UIKit
import AirMouseProtocol

/// The touch surface.
///
/// A raw UIView rather than SwiftUI gestures: this needs every touch-down,
/// move, up *and cancel* with its own identity, and SwiftUI's gesture system
/// abstracts exactly that away. `touchesCancelled` in particular has no SwiftUI
/// equivalent, and it is the event that stops a held mouse button being
/// stranded on the Mac when a call comes in mid-drag (ADR-0006).
///
/// This is a deliberately plain first pass — pan, tap, two-finger scroll,
/// long-press for right click. The web client's tuned acceleration, drag-lock,
/// edge strips and momentum are not here yet; they belong in a tested,
/// platform-agnostic gesture core rather than being re-improvised in a view.
struct TrackpadView: UIViewRepresentable {
    let send: (ClientMessage) -> Void
    let haptics: Haptics

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        view.send = send
        view.haptics = haptics
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: TouchSurface, context: Context) {
        view.send = send
    }
}

final class TouchSurface: UIView {
    var send: ((ClientMessage) -> Void)?
    var haptics: Haptics?

    private var lastPoint: CGPoint?
    private var startPoint: CGPoint?
    private var startTime: TimeInterval = 0
    private var isScrolling = false
    private var lastScrollPoint: CGPoint?
    private var buttonIsDown = false
    private var longPressTimer: Timer?
    private var longPressFired = false

    private let tapMaxDuration: TimeInterval = 0.22
    private let tapMaxDistance: CGFloat = 12
    private let longPressDelay: TimeInterval = 0.5
    private let longPressSlop: CGFloat = 10
    /// Matches the web client's baseSensitivity so the two feel comparable
    /// until the real acceleration curve is ported.
    private let sensitivity: CGFloat = 1.3

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches ?? touches
        if all.count >= 2 {
            cancelLongPress()
            isScrolling = true
            lastScrollPoint = midpoint(of: all)
            return
        }

        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        startPoint = point
        lastPoint = point
        startTime = touch.timestamp
        longPressFired = false

        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.longPressFired = true
                self.send?(.click(button: .right, action: .tap))
                self.haptics?.play(.rightClick)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches ?? touches

        if isScrolling, all.count >= 2 {
            let point = midpoint(of: all)
            if let last = lastScrollPoint {
                let dx = point.x - last.x
                let dy = point.y - last.y
                if abs(dx) > 0.3 || abs(dy) > 0.3 {
                    send?(.scroll(dx: Double(dx) * 0.35, dy: Double(dy) * 0.35))
                    if abs(dy) > 6 || abs(dx) > 6 { haptics?.play(.scrollDetent) }
                }
            }
            lastScrollPoint = point
            return
        }

        guard let touch = touches.first, let last = lastPoint else { return }
        let point = touch.location(in: self)

        if let start = startPoint, hypot(point.x - start.x, point.y - start.y) > longPressSlop {
            cancelLongPress()
        }

        let dx = point.x - last.x
        let dy = point.y - last.y
        lastPoint = point
        send?(.trackpad(dx: Double(dx * sensitivity), dy: Double(dy * sensitivity)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()

        let remaining = (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }

        if isScrolling {
            if remaining.isEmpty { reset() }
            return
        }

        if buttonIsDown {
            send?(.click(button: .left, action: .up))
            haptics?.play(.dragDrop)
            buttonIsDown = false
        } else if !longPressFired,
                  let touch = touches.first,
                  let start = startPoint,
                  touch.timestamp - startTime < tapMaxDuration,
                  hypot(touch.location(in: self).x - start.x,
                        touch.location(in: self).y - start.y) < tapMaxDistance {
            send?(.click(button: .left, action: .tap))
            haptics?.play(.tap)
        }

        if remaining.isEmpty { reset() }
    }

    /// iOS cancels touches on interruption — an incoming call, a system edge
    /// swipe, a notification. `touchesEnded` never fires in that case, so
    /// without this the `up` matching a drag's `down` is never sent and the Mac
    /// is left with the button held, dragging across everything the cursor
    /// touches (ADR-0006).
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        if buttonIsDown {
            send?(.click(button: .left, action: .up))
            buttonIsDown = false
        }
        reset()
    }

    // MARK: - Helpers

    private func midpoint(of touches: Set<UITouch>) -> CGPoint {
        let points = touches.map { $0.location(in: self) }
        let x = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func reset() {
        isScrolling = false
        lastScrollPoint = nil
        lastPoint = nil
        startPoint = nil
        longPressFired = false
    }
}
