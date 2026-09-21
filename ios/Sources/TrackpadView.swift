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
    /// Anything on screen that a touch here should dismiss.
    var onTouchDown: () -> Void = {}

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        view.send = send
        view.onTouchDown = onTouchDown
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
        // Refreshed too: it closes over view state that changes, and a stale
        // closure here would dismiss against a value from a previous render.
        view.onTouchDown = onTouchDown
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
    var onTouchDown: () -> Void = {}

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
        // Ask for the display's real rate. On ProMotion this is the difference
        // between momentum drawn 60 times a second and 120 — and the Info.plist
        // key that unlocks it (CADisableMinimumFrameDurationOnPhone) is
        // required as well, or this range is quietly clamped to 60.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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
        onTouchDown()
        report(touches, moved: false)
        play(engine.touchesBegan(convert(touches),
                                 all: convert(active(in: event) ?? touches),
                                 at: timestamp(touches, event)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Every move, not only while dragging: the grid throttles ripples by
        // distance and time itself, and the glow that follows the finger needs
        // its position continuously to exist at all.
        report(touches, moved: true)

        // One finger: replay every sample the digitiser actually took.
        //
        // UIKit delivers touchesMoved once per frame, but the screen samples
        // far faster than it draws — up to 240Hz on ProMotion — and hands the
        // intermediate samples over only if they are asked for. Reading one
        // and discarding the rest throws away most of the movement's shape: a
        // fast flick arrives as a single long jump, and the engine's speed
        // estimate, which drives the whole acceleration curve, is computed from
        // that one coarse delta.
        //
        // Deliberately single-touch. Coalesced samples are per touch and two
        // fingers rarely have the same number, so replaying a multi-touch
        // gesture means inventing an interleaving. Two-finger scroll is also
        // heavily smoothed downstream, where this precision would not survive.
        if let touch = touches.first,
           touches.count == 1,
           (active(in: event)?.count ?? 1) == 1,
           let samples = event?.coalescedTouches(for: touch),
           samples.count > 1 {
            replay(samples, identifiedBy: touch)
            return
        }

        play(engine.touchesMoved(convert(touches),
                                 all: convert(active(in: event) ?? touches),
                                 at: timestamp(touches, event)))
    }

    /// Feeds each intermediate sample to the engine in order, with its own
    /// timestamp.
    ///
    /// The identity comes from the *parent* touch, not the samples. Coalesced
    /// touches are separate UITouch objects, so identifying them the usual way
    /// would present every sample as a different finger arriving and leaving —
    /// which is not a subtle failure, it is every gesture falling apart.
    private func replay(_ samples: [UITouch], identifiedBy touch: UITouch) {
        let id = ObjectIdentifier(touch).hashValue
        var effects: [GestureEffect] = []
        for sample in samples {
            let point = sample.location(in: self)
            let value = Touch(id: id, x: Double(point.x), y: Double(point.y))
            effects += engine.touchesMoved([value], all: [value], at: sample.timestamp)
        }
        play(merged(effects))
    }

    /// Sums adjacent movement into one message per frame.
    ///
    /// Replaying four samples would otherwise send four packets where one used
    /// to go — quadrupling the packet rate to win precision we have already
    /// won, since the engine has *already* done its per-sample speed and
    /// acceleration maths by the time these come back. Deltas add, and addition
    /// commutes, so one summed message moves the cursor exactly as far as four
    /// separate ones.
    ///
    /// Only adjacent runs are merged, and anything else flushes the
    /// accumulator first: a button press between two movements must stay
    /// between them, or a drag begins from the wrong place.
    private func merged(_ effects: [GestureEffect]) -> [GestureEffect] {
        var output: [GestureEffect] = []
        var trackpad: (dx: Double, dy: Double)?
        var scroll: (dx: Double, dy: Double)?

        func flush() {
            if let trackpad {
                output.append(.send(.trackpad(dx: trackpad.dx, dy: trackpad.dy)))
            }
            if let scroll {
                output.append(.send(.scroll(dx: scroll.dx, dy: scroll.dy)))
            }
            trackpad = nil
            scroll = nil
        }

        for effect in effects {
            switch effect {
            case .send(.trackpad(let dx, let dy)):
                trackpad = ((trackpad?.dx ?? 0) + dx, (trackpad?.dy ?? 0) + dy)
            case .send(.scroll(let dx, let dy)):
                scroll = ((scroll?.dx ?? 0) + dx, (scroll?.dy ?? 0) + dy)
            default:
                flush()
                output.append(effect)
            }
        }
        flush()
        return output
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = (active(in: event) ?? []).filter { touch in
            !touches.contains(touch)
        }
        if remaining.isEmpty { effects?.touchUp() }
        play(engine.touchesEnded(convert(touches),
                                 remaining: convert(remaining),
                                 at: timestamp(touches, event)))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        effects?.touchUp()
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

    /// Feeds the grid simulation. Only the first touch drives the glow — with
    /// two fingers down the midpoint would sit between them, glowing where
    /// nothing is being touched.
    private func report(_ touches: Set<UITouch>, moved: Bool) {
        guard let touch = touches.min(by: { $0.timestamp < $1.timestamp }) else { return }
        let point = touch.location(in: self)
        let now = CACurrentMediaTime()
        if moved {
            effects?.touchMoved(x: Double(point.x), y: Double(point.y), at: now)
        } else {
            effects?.touchDown(x: Double(point.x), y: Double(point.y), at: now)
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
