import Foundation

/// Every tunable in the gesture layer, with the values the web client shipped.
///
/// These are the product. The wire protocol is trivial; what makes Air Mouse
/// feel like a trackpad rather than a remote control is this set of numbers and
/// the curves below, arrived at by feel over many iterations. They are ported
/// verbatim rather than re-derived, and the tests assert the curves rather than
/// the outcomes, so a later "cleanup" cannot quietly change how it feels.
public struct GestureConfig: Equatable, Sendable {

    // MARK: Pointer

    /// Applied to every delta before the acceleration factor.
    public var baseSensitivity: Double = 1.3

    // MARK: Tap and long press

    /// Longer than this and a touch is a drag, not a tap.
    public var tapMaxDuration: Double = 0.220
    /// Further than this and a touch is a drag, not a tap.
    public var tapMaxDistance: Double = 12
    /// A second tap within this window arms drag mode.
    ///
    /// Shortened from 0.3s. The second touch of a deliberate double tap comes
    /// down fast; a finger coming back down a third of a second after a click
    /// is far more often just carrying on moving the cursor — and inside this
    /// window it arms a drag.
    public var doubleTapWindow: Double = 0.220
    /// Hold still this long for a right click.
    public var longPressDuration: Double = 0.500
    /// Drift beyond this cancels the pending right click.
    public var longPressSlop: Double = 10
    /// After the second tap of a double tap, holding this long picks up the
    /// drag without needing to move at all.
    ///
    /// Doubled from 0.14s, which was shorter than the natural pause between
    /// putting a finger down and starting to move it. Click something, rest a
    /// finger to carry on, and the pause alone picked up whatever was under the
    /// cursor.
    public var dragHoldDuration: Double = 0.280
    /// …or moving this far does the same, sooner.
    ///
    /// Raised from 6: the second touch of a double tap is often already sliding
    /// as it lands, and six points of that is nothing — which is how moving the
    /// cursor turned into dragging whatever was under it.
    public var dragActivateDistance: Double = 14
    /// How near the previous tap the second one has to land to count as a
    /// double tap.
    ///
    /// There was no distance test at all: any touch within the double-tap
    /// window armed a drag, however far across the surface it was. Tapping,
    /// then reaching somewhere else and moving, picked things up and carried
    /// them.
    public var doubleTapMaxDistance: Double = 30
    /// A two-finger touch released faster than this is a right click.
    public var twoFingerTapMaxDuration: Double = 0.250

    // MARK: Scrolling

    /// Time constant of the scroll-velocity filter, in seconds.
    ///
    /// A time constant rather than an EMA alpha, because alpha is per *event*
    /// and the event rate is no longer fixed: coalesced touches deliver up to
    /// four samples a frame and the display link now runs at 120Hz. A fixed
    /// alpha silently shrinks its own window as the rate rises — at 240Hz it
    /// smooths over 4ms of history instead of 17ms — which is what made fast
    /// and slow gestures start returning the same acceleration factor.
    ///
    /// 21ms reproduces the old alpha of 0.55 at 60Hz exactly
    /// (tau = -dt / ln(1 - alpha)), and now behaves the same at any rate.
    public var scrollVelocityTau: Double = 0.021
    /// The same, for pointer speed. Shorter, because the pointer should react
    /// to a change of pace faster than a scroll should.
    public var pointerVelocityTau: Double = 0.012
    /// Deltas smaller than this are noise.
    public var scrollDeadzone: Double = 0.3

    /// Below this speed the scroll gain is at its floor — the precision end.
    public var scrollPrecisionSpeed: Double = 0.0
    /// At and above this speed the gain has reached its ceiling.
    public var scrollFullSpeed: Double = 14.0
    /// Gain for the slowest movement. Low, so a careful drag can place a long
    /// document exactly rather than approximately.
    public var scrollMinGain: Double = 0.30
    /// Gain for the fastest. Bounded, unlike the old curve, which kept
    /// accelerating for as long as you kept flicking harder.
    public var scrollMaxGain: Double = 1.5
    /// Scroll output is now *distance* travelled times the acceleration factor,
    /// where it used to be a fixed amount per event in the direction of travel.
    ///
    /// The old form discarded how far the finger actually moved, so a hard
    /// flick — high speed, short duration, few events — covered barely more
    /// ground than a slow drag. That is the "exhausting to scroll a long
    /// document" problem: there was no way to buy distance with effort. It also
    /// made total scroll proportional to the sample rate.
    ///
    /// These are smaller than the old values because they now multiply points
    /// rather than a bare sign. Global magnitude is better tuned on the Mac
    /// (AIRMOUSE_SCROLL_SCALE), which needs no rebuild of this app.
    public var twoFingerScrollScale: Double = 0.18
    public var edgeScrollScale: Double = 0.20
    /// Per 60Hz frame. Applied as friction^frames, so momentum decays over the
    /// same wall-clock time whether the display link runs at 60 or 120.
    // MARK: Pinch to zoom

    /// How much deliberate spreading it takes to turn a pan into a zoom.
    ///
    /// Panning and zooming cannot run together, because ⌘-scroll does not *add*
    /// zoom to a scroll — it reinterprets it, and Figma zooms around the cursor.
    /// So a two-finger gesture is always exactly one of the two, and switches
    /// between them as the motion changes.
    ///
    /// What counts toward zooming is spreading that *dominates the recent
    /// motion* — not the total change in separation since the gesture began.
    /// The total was the first attempt, and it broke panning: no hand holds its
    /// fingers exactly apart across a long pan, and a slow drift reached the
    /// threshold a couple of hundred points in, stopping the pan dead.
    public var pinchActivationDistance: Double = 8
    /// The window "recent motion" is judged over, in seconds.
    public var pinchEvidenceWindow: Double = 0.2
    /// How much faster the separation must be changing than the midpoint is
    /// moving before spreading counts as a pinch.
    ///
    /// The number that matters here is 0.5. A pinch with one finger held still
    /// moves the midpoint at exactly half the rate the separation changes, so a
    /// dominance of 1.33 accepts it comfortably — while anything where the pair
    /// is also travelling at comparable speed stays a pan. Both at once is a
    /// pan, because both at once cannot be done.
    public var pinchDominance: Double = 1.33
    /// While zooming: midpoint travel at or above this multiple of the change
    /// in separation hands the gesture back to panning.
    ///
    /// Set at 1, with `pinchDominance` above it, which leaves a band between
    /// the two where nothing switches. Without that band a gesture sitting near
    /// the boundary would flicker between modes on every frame.
    public var panReclaimRatio: Double = 1.0
    /// And how far the pair has to travel together, while that holds, before
    /// the switch — enough that a wobble mid-pinch does not throw it back.
    public var panReclaimDistance: Double = 6
    /// Separation changes smaller than this are hand tremor.
    public var pinchDeadzone: Double = 0.4
    /// Points of separation to units of ⌘-scroll.
    public var pinchZoomScale: Double = 0.08
    /// Whether spreading the fingers zooms out rather than in.
    public var pinchZoomInverted: Bool = false

    public var momentumFriction: Double = 0.93
    /// Below this at release, momentum is not worth starting.
    public var momentumMinVelocity: Double = 1.2
    /// Below this, momentum stops.
    public var momentumStopVelocity: Double = 0.1

    // MARK: Edges

    // There is no left edge strip any more. It switched desktop on a one-finger
    // sideways movement that started in the leftmost 15% of the surface —
    // about a thumb's width — and did not move the cursor at all, so reaching
    // for the left side of the screen and moving found nothing happening and
    // then a desktop switch. Three fingers do that now, as on a trackpad.
    /// Rightmost fraction that scrolls vertically.
    public var rightEdgeFraction: Double = 0.10
    /// Bottom fraction that scrolls horizontally.
    public var bottomEdgeFraction: Double = 0.10
    /// How far three fingers must travel together to fire their gesture.
    ///
    /// Once per gesture, in whichever direction dominates: sideways switches
    /// desktop, up opens Mission Control, down opens App Exposé. It fires at a
    /// threshold rather than following the fingers, because the interactive
    /// version — the desktop sliding with you, cancellable halfway — is driven
    /// by the Dock's private gesture pipeline, which nothing outside it can
    /// reach.
    public var threeFingerSwipeDistance: Double = 50

    /// The rate every "per frame" number here is expressed against.
    ///
    /// Velocities are measured in points per 60Hz frame so that the curve
    /// thresholds below keep the meaning they were tuned with. It is a unit,
    /// not a cadence — nothing is sampled at 60Hz any more.
    public static let referenceFrameRate: Double = 60

    public init() {}

    // MARK: Curves

    /// Pointer acceleration.
    ///
    /// Below 2px/frame the movement is *damped*, not merely un-accelerated:
    /// precision work — landing on a menu item, placing a caret — happens in
    /// that range, and 1:1 tracking there feels twitchy on a surface this
    /// small. Above 2px it grows with a deliberately shallow exponent, so
    /// crossing a large display stays possible without the pointer running away.
    public func accelerationFactor(forSpeed speed: Double) -> Double {
        if speed < 2 {
            return 0.45 + (speed / 2) * 0.55
        }
        return 1.0 + pow(speed - 2, 1.1) * 0.10
    }

    /// Scroll acceleration, as an S.
    ///
    /// The previous shape ramped linearly, sat flat through the middle, then
    /// grew without bound — so the top end kept getting faster the harder you
    /// flicked, and the bottom end never got genuinely fine. A smoothstep is
    /// flat at *both* ends, which is exactly the two properties wanted: a very
    /// slow drag stays near `scrollMinGain` and can place a document precisely,
    /// and a hard flick tops out at `scrollMaxGain` instead of running away.
    ///
    /// Everything between is the S, so there is no point at which the response
    /// changes character — the flat middle zone of the old curve was a seam you
    /// could feel when a gesture crossed it.
    public func scrollFactor(forSpeed speed: Double) -> Double {
        let span = max(scrollFullSpeed - scrollPrecisionSpeed, 0.0001)
        let t = min(max((speed - scrollPrecisionSpeed) / span, 0), 1)
        // Smoothstep: zero slope at both ends, steepest in the middle.
        let eased = t * t * (3 - 2 * t)
        return scrollMinGain + (scrollMaxGain - scrollMinGain) * eased
    }
}
