import SwiftUI
import UIKit
import AirMouseProtocol
import AirMouseGestures

/// The touch surface.
///
/// A raw UIView rather than SwiftUI gestures: this needs every touch-down,
/// move, up *and cancel* with its own identity, and SwiftUI's gesture system
/// abstracts exactly that away. `touchesCancelled` in particular has no SwiftUI
/// equivalent, and it is the event that stops a held mouse button being
/// stranded on the Mac when a call comes in mid-drag (ADR-0006).
///
/// This view does no gesture reasoning of its own. It translates UIKit touches
/// into `GestureEngine` input and plays back the effects — all the tuning lives
/// in AirMouseKit, where it can be tested without a device.
struct TrackpadView: UIViewRepresentable {
    let send: (ClientMessage) -> Void
    let haptics: Haptics
    let effects: SurfaceEffects

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        view.send = send
        view.haptics = haptics
        view.effects = effects
        // Clear, not black: this sits on top of the dot grid in the ZStack,
        // and an opaque background hides it completely.
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: TouchSurface, context: Context) {
        view.send = send
    }

    static func dismantleUIView(_ view: TouchSurface, coordinator: Coordinator) {
        // The view going away must not leave the Mac holding a button.
        view.releaseEverything()
    }
}

final class TouchSurface: UIView {
    var send: ((ClientMessage) -> Void)?
    var haptics: Haptics?
    var effects: SurfaceEffects?

    private let engine = GestureEngine()
    private var displayLink: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopTicking()
            releaseEverything()
        } else {
            startTicking()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The engine locates the edge strips proportionally, so it needs the
        // real size — and needs it again on rotation, which the protocol
        // supports precisely so the phone can be held either way.
        engine.surfaceWidth = Double(bounds.width)
        engine.surfaceHeight = Double(bounds.height)
    }

    // MARK: - Ticking
    //
    // The long press, the drag pick-up and momentum scrolling all happen
    // without any touch arriving, so something has to advance time. A display
    // link rather than a Timer: momentum is drawn frame by frame, and matching
    // the display's cadence is what stops it stuttering.

    private func startTicking() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        play(engine.tick(at: link.timestamp))
    }

    func releaseEverything() {
        play(engine.releaseEverything())
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        spawnRipples(for: touches)
        play(engine.touchesBegan(convert(touches),
                                 all: convert(active(in: event) ?? touches),
                                 at: timestamp(touches, event)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only while dragging something: a ripple under every move would light
        // the whole grid continuously and stop meaning anything.
        if engine.isButtonHeld { spawnRipples(for: touches) }
        play(engine.touchesMoved(convert(touches),
                                 all: convert(active(in: event) ?? touches),
                                 at: timestamp(touches, event)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = (active(in: event) ?? []).filter { touch in
            !touches.contains(touch)
        }
        play(engine.touchesEnded(convert(touches),
                                 remaining: convert(remaining),
                                 at: timestamp(touches, event)))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        play(engine.touchesCancelled(at: timestamp(touches, event)))
    }

    // MARK: - Helpers

    /// Touches still down, excluding those already lifted or cancelled.
    private func active(in event: UIEvent?) -> Set<UITouch>? {
        guard let all = event?.allTouches else { return nil }
        return all.filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    private func convert(_ touches: some Sequence<UITouch>) -> [Touch] {
        touches.map { touch in
            let point = touch.location(in: self)
            // Identified by the object's address: UITouch instances are reused
            // for the life of one finger's contact, which is exactly the
            // identity the engine needs.
            return Touch(id: ObjectIdentifier(touch).hashValue,
                         x: Double(point.x), y: Double(point.y))
        }
    }

    /// UITouch timestamps share a clock with CADisplayLink, so the engine sees
    /// one consistent timeline whether it is being advanced by a touch or by a
    /// frame.
    private func timestamp(_ touches: Set<UITouch>, _ event: UIEvent?) -> Double {
        touches.first?.timestamp ?? event?.timestamp ?? CACurrentMediaTime()
    }

    private func spawnRipples(for touches: Set<UITouch>) {
        let now = CACurrentMediaTime()
        for touch in touches {
            let point = touch.location(in: self)
            effects?.ripple(x: Double(point.x), y: Double(point.y), at: now)
        }
    }

    private func play(_ effects: [GestureEffect]) {
        for effect in effects {
            switch effect {
            case .send(let message):
                send?(message)
            case .haptic(let cue):
                haptics?.play(cue)
            }
        }
    }
}
