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
    public var doubleTapWindow: Double = 0.300
    /// Hold still this long for a right click.
    public var longPressDuration: Double = 0.500
    /// Drift beyond this cancels the pending right click.
    public var longPressSlop: Double = 10
    /// After the second tap of a double tap, holding this long picks up the
    /// drag without needing to move at all.
    public var dragHoldDuration: Double = 0.140
    /// …or moving this far does the same, sooner.
    public var dragActivateDistance: Double = 6
    /// A two-finger touch released faster than this is a right click.
    public var twoFingerTapMaxDuration: Double = 0.250

    // MARK: Scrolling

    /// EMA alpha. Higher is more responsive, lower is smoother.
    public var scrollSmoothing: Double = 0.55
    /// Deltas smaller than this are noise.
    public var scrollDeadzone: Double = 0.3
    public var twoFingerScrollScale: Double = 0.35
    public var edgeScrollScale: Double = 0.40
    public var momentumFriction: Double = 0.93
    /// Below this at release, momentum is not worth starting.
    public var momentumMinVelocity: Double = 1.2
    /// Below this, momentum stops.
    public var momentumStopVelocity: Double = 0.1

    // MARK: Edges

    /// Leftmost fraction of the surface that switches desktop.
    ///
    /// 15% rather than something tighter because iOS claims the first few
    /// points for its own back-swipe, so a gesture starting at x=0 never
    /// reaches the app at all.
    public var leftEdgeFraction: Double = 0.15
    /// Rightmost fraction that scrolls vertically.
    public var rightEdgeFraction: Double = 0.10
    /// Bottom fraction that scrolls horizontally.
    public var bottomEdgeFraction: Double = 0.10
    /// Horizontal travel needed to commit a desktop switch.
    public var desktopSwitchDistance: Double = 40

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

    /// Scroll acceleration. Same shape as the pointer curve but with a wider
    /// flat zone, because scrolling has a natural rhythm that acceleration
    /// disrupts more noticeably than it does pointing.
    public func scrollFactor(forSpeed speed: Double) -> Double {
        if speed < 1.5 {
            return 0.25 + (speed / 1.5) * 0.75
        }
        if speed > 3 {
            return 1.0 + pow(speed - 3, 1.05) * 0.10
        }
        return 1.0
    }
}
