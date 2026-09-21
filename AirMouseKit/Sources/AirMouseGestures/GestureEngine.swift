import Foundation
import AirMouseProtocol

/// One finger on the surface, in points.
public struct Touch: Equatable, Sendable {
    public let id: Int
    public let x: Double
    public let y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// What the host should do as a result of a gesture.
///
/// The engine never sends or vibrates anything itself. It is a pure function of
/// its inputs, which is what allows the whole feel of the product to be tested
/// in milliseconds instead of by hand on a phone.
public enum GestureEffect: Equatable, Sendable {
    case send(ClientMessage)
    case haptic(HapticCue)
}

public enum HapticCue: Equatable, Sendable {
    case tap
    case rightClick
    case dragPickUp
    case dragDrop
    case doubleTap
    case scrollDetent
    case desktopSwitch
    case edgeEnter
}

/// The trackpad gesture state machine, ported from the web client.
///
/// Time and touches are passed in; nothing is read from a clock or a view. The
/// host calls `tick` regularly (a display link) so the engine can fire the
/// things that happen without input — the long press, the drag hold, and
/// momentum scrolling.
public final class GestureEngine {

    public var config: GestureConfig

    /// Surface size in points, needed to locate the edge strips.
    public var surfaceWidth: Double
    public var surfaceHeight: Double

    // Pointer state
    private var startPoint: (x: Double, y: Double)?
    private var lastPoint: (x: Double, y: Double)?
    private var startTime: Double = 0
    private var isMoving = false

    // Tap / drag state
    private var wasLastTouchTap = false
    private var lastTouchEndTime: Double = -.greatestFiniteMagnitude
    private var dragArmed = false
    private var dragDownSent = false
    private var dragHoldDeadline: Double?
    private var longPressDeadline: Double?
    private var longPressFired = false

    // Scroll state
    private enum EdgeScroll { case vertical, horizontal }
    private var edgeScroll: EdgeScroll?
    private var isTwoFingerScrolling = false
    private var lastScrollPoint: (x: Double, y: Double)?
    private var scrollVelocityX: Double = 0
    private var scrollVelocityY: Double = 0
    private var momentumVelocityX: Double = 0
    private var momentumVelocityY: Double = 0
    private var momentumActive = false

    // Desktop switch
    private var edgeSwipe: DesktopDirection?

    /// True while the Mac is holding a mouse button down because of this
    /// engine. The host needs it to guarantee a release on teardown (ADR-0006).
    public private(set) var isButtonHeld = false

    public init(config: GestureConfig = GestureConfig(),
                surfaceWidth: Double = 0,
                surfaceHeight: Double = 0) {
        self.config = config
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
    }

    // MARK: - Touch input

    public func touchesBegan(_ touches: [Touch], all: [Touch], at time: Double) -> [GestureEffect] {
        var effects: [GestureEffect] = []
        // Any new touch stops momentum — catching a moving list is the gesture
        // people expect, and it must feel immediate.
        effects += stopMomentum()

        if all.count >= 2 {
            cancelLongPress()
            cancelDragHold()
            isTwoFingerScrolling = true
            isMoving = false
            lastScrollPoint = midpoint(of: all)
            startTime = time
            return effects
        }

        guard let touch = touches.first else { return effects }
        startPoint = (touch.x, touch.y)
        lastPoint = (touch.x, touch.y)
        startTime = time
        longPressFired = false
        edgeScroll = nil
        edgeSwipe = nil

        if touch.x < surfaceWidth * config.leftEdgeFraction {
            edgeSwipe = .left
            isMoving = false
            effects.append(.haptic(.edgeEnter))
        } else if touch.x > surfaceWidth * (1 - config.rightEdgeFraction) {
            // The right strip scrolls, and — unlike the web client, where the
            // "next desktop" branch was dead code that nothing ever set — a
            // horizontal flick here switches desktop forward. Without it only
            // the previous desktop was ever reachable.
            edgeSwipe = .right
            edgeScroll = .vertical
            isMoving = false
            lastScrollPoint = (touch.x, touch.y)
            scrollVelocityY = 0
            effects.append(.haptic(.edgeEnter))
        } else if touch.y > surfaceHeight * (1 - config.bottomEdgeFraction) {
            edgeScroll = .horizontal
            isMoving = false
            lastScrollPoint = (touch.x, touch.y)
            scrollVelocityX = 0
            effects.append(.haptic(.edgeEnter))
        } else {
            isMoving = true
            if wasLastTouchTap, time - lastTouchEndTime < config.doubleTapWindow {
                dragArmed = true
                dragDownSent = false
                dragHoldDeadline = time + config.dragHoldDuration
            } else {
                longPressDeadline = time + config.longPressDuration
            }
        }
        return effects
    }

    public func touchesMoved(_ touches: [Touch], all: [Touch], at time: Double) -> [GestureEffect] {
        var effects: [GestureEffect] = []

        if isTwoFingerScrolling, all.count >= 2 {
            let point = midpoint(of: all)
            defer { lastScrollPoint = point }
            guard let last = lastScrollPoint else { return effects }
            let rawX = point.x - last.x
            let rawY = point.y - last.y
            guard abs(rawX) > config.scrollDeadzone || abs(rawY) > config.scrollDeadzone else { return effects }
            effects += smoothedScroll(rawX: rawX, rawY: rawY,
                                      scale: config.twoFingerScrollScale, detentAbove: 6)
            return effects
        }

        guard let touch = touches.first else { return effects }

        if let edge = edgeScroll, let last = lastScrollPoint {
            switch edge {
            case .vertical:
                let raw = touch.y - last.y
                lastScrollPoint = (touch.x, touch.y)
                guard abs(raw) > config.scrollDeadzone else { return effects }
                effects += smoothedScroll(rawX: 0, rawY: raw,
                                          scale: config.edgeScrollScale, detentAbove: 5)
            case .horizontal:
                let raw = touch.x - last.x
                lastScrollPoint = (touch.x, touch.y)
                guard abs(raw) > config.scrollDeadzone else { return effects }
                effects += smoothedScroll(rawX: raw, rawY: 0,
                                          scale: config.edgeScrollScale, detentAbove: 5)
            }
            return effects
        }

        guard isMoving, let last = lastPoint, let start = startPoint else { return effects }

        if longPressDeadline != nil,
           hypot(touch.x - start.x, touch.y - start.y) > config.longPressSlop {
            cancelLongPress()
        }

        if dragArmed, !dragDownSent,
           hypot(touch.x - start.x, touch.y - start.y) > config.dragActivateDistance {
            effects += pressLeftButton()
        }

        // While the drag is armed but not yet committed, follow the finger
        // without sending anything: otherwise the pointer jumps the moment the
        // button goes down, because the deltas since touch-down were discarded.
        guard !dragArmed || dragDownSent else {
            lastPoint = (touch.x, touch.y)
            return effects
        }

        let dx = touch.x - last.x
        let dy = touch.y - last.y
        lastPoint = (touch.x, touch.y)

        let speed = hypot(dx, dy)
        let factor = config.accelerationFactor(forSpeed: speed)
        effects.append(.send(.trackpad(
            dx: dx * config.baseSensitivity * factor,
            dy: dy * config.baseSensitivity * factor)))
        return effects
    }

    public func touchesEnded(_ touches: [Touch], remaining: [Touch], at time: Double) -> [GestureEffect] {
        var effects: [GestureEffect] = []
        cancelLongPress()
        cancelDragHold()

        let touch = touches.first
        let duration = time - startTime

        if isTwoFingerScrolling {
            // Two fingers down and up quickly, without scrolling anywhere, is a
            // right click — the trackpad convention.
            if duration < config.twoFingerTapMaxDuration,
               abs(scrollVelocityX) < 1, abs(scrollVelocityY) < 1 {
                effects.append(.send(.click(button: .right, action: .tap)))
                effects.append(.haptic(.rightClick))
            }
            if remaining.isEmpty {
                effects += handOffToMomentum()
                reset()
            }
            return effects
        }

        if let direction = edgeSwipe, let touch, let start = startPoint {
            let dx = touch.x - start.x
            let travelled = abs(dx) > config.desktopSwitchDistance
            // Direction comes from the swipe, not from which edge started it —
            // an edge is where the gesture begins, not what it means.
            if travelled {
                effects.append(.send(.switchDesktop(direction: dx < 0 ? .left : .right)))
                effects.append(.haptic(.desktopSwitch))
                edgeScroll = nil        // a committed swipe is not also a scroll
                _ = direction
            }
        }

        if dragArmed {
            if dragDownSent {
                effects += releaseLeftButton()
            } else {
                // Armed but never committed: the user tapped twice and let go.
                effects.append(.send(.click(button: .left, action: .doubleTap)))
                effects.append(.haptic(.doubleTap))
            }
            wasLastTouchTap = false
        } else if !longPressFired, isMoving, edgeScroll == nil,
                  duration < config.tapMaxDuration,
                  let touch, let start = startPoint,
                  hypot(touch.x - start.x, touch.y - start.y) < config.tapMaxDistance {
            effects.append(.send(.click(button: .left, action: .tap)))
            effects.append(.haptic(.tap))
            wasLastTouchTap = true
        } else {
            wasLastTouchTap = false
        }

        lastTouchEndTime = time
        if remaining.isEmpty {
            effects += handOffToMomentum()
            reset()
        }
        return effects
    }

    /// The system took the touches away — an incoming call, a system edge
    /// swipe, a notification. `touchesEnded` never arrives, so a held button
    /// would otherwise stay held and drag across everything (ADR-0006).
    public func touchesCancelled(at time: Double) -> [GestureEffect] {
        var effects: [GestureEffect] = []
        cancelLongPress()
        cancelDragHold()
        if isButtonHeld {
            effects += releaseLeftButton()
        }
        reset()
        wasLastTouchTap = false
        return effects
    }

    /// Fires everything that happens without a touch: the pending right click,
    /// the drag pick-up, and momentum scrolling. Call it from a display link.
    public func tick(at time: Double) -> [GestureEffect] {
        var effects: [GestureEffect] = []

        if let deadline = longPressDeadline, time >= deadline {
            longPressDeadline = nil
            longPressFired = true
            effects.append(.send(.click(button: .right, action: .tap)))
            effects.append(.haptic(.rightClick))
        }

        if let deadline = dragHoldDeadline, time >= deadline {
            dragHoldDeadline = nil
            if dragArmed, !dragDownSent {
                effects += pressLeftButton()
            }
        }

        if momentumActive {
            momentumVelocityX *= config.momentumFriction
            momentumVelocityY *= config.momentumFriction
            if abs(momentumVelocityX) < config.momentumStopVelocity,
               abs(momentumVelocityY) < config.momentumStopVelocity {
                momentumActive = false
            } else {
                effects.append(.send(.scroll(
                    dx: sign(momentumVelocityX) * config.scrollFactor(forSpeed: abs(momentumVelocityX)) * config.twoFingerScrollScale,
                    dy: sign(momentumVelocityY) * config.scrollFactor(forSpeed: abs(momentumVelocityY)) * config.twoFingerScrollScale)))
            }
        }

        return effects
    }

    /// Releases anything held, for teardown and disconnection.
    public func releaseEverything() -> [GestureEffect] {
        var effects: [GestureEffect] = []
        if isButtonHeld { effects += releaseLeftButton() }
        momentumActive = false
        return effects
    }

    // MARK: - Helpers

    private func pressLeftButton() -> [GestureEffect] {
        dragDownSent = true
        isButtonHeld = true
        return [.send(.click(button: .left, action: .down)), .haptic(.dragPickUp)]
    }

    private func releaseLeftButton() -> [GestureEffect] {
        dragDownSent = false
        isButtonHeld = false
        return [.send(.click(button: .left, action: .up)), .haptic(.dragDrop)]
    }

    private func smoothedScroll(rawX: Double, rawY: Double,
                                scale: Double, detentAbove: Double) -> [GestureEffect] {
        scrollVelocityX = config.scrollSmoothing * rawX + (1 - config.scrollSmoothing) * scrollVelocityX
        scrollVelocityY = config.scrollSmoothing * rawY + (1 - config.scrollSmoothing) * scrollVelocityY
        let speedX = abs(scrollVelocityX)
        let speedY = abs(scrollVelocityY)

        var effects: [GestureEffect] = [.send(.scroll(
            dx: sign(scrollVelocityX) * config.scrollFactor(forSpeed: speedX) * scale,
            dy: sign(scrollVelocityY) * config.scrollFactor(forSpeed: speedY) * scale))]
        if speedX > detentAbove || speedY > detentAbove {
            effects.append(.haptic(.scrollDetent))
        }
        return effects
    }

    private func handOffToMomentum() -> [GestureEffect] {
        guard abs(scrollVelocityX) >= config.momentumMinVelocity
                || abs(scrollVelocityY) >= config.momentumMinVelocity
        else { return [] }
        momentumVelocityX = scrollVelocityX
        momentumVelocityY = scrollVelocityY
        momentumActive = true
        return []
    }

    private func stopMomentum() -> [GestureEffect] {
        momentumActive = false
        momentumVelocityX = 0
        momentumVelocityY = 0
        return []
    }

    private func cancelLongPress() { longPressDeadline = nil }
    private func cancelDragHold() { dragHoldDeadline = nil }

    private func reset() {
        isMoving = false
        isTwoFingerScrolling = false
        edgeScroll = nil
        edgeSwipe = nil
        dragArmed = false
        startPoint = nil
        lastPoint = nil
        lastScrollPoint = nil
        // Deliberately not cleared: scroll velocity is handed to momentum, and
        // wasLastTouchTap has to survive to the next touch for double-tap.
        scrollVelocityX = 0
        scrollVelocityY = 0
    }

    private func midpoint(of touches: [Touch]) -> (x: Double, y: Double) {
        let x = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let y = touches.map(\.y).reduce(0, +) / Double(touches.count)
        return (x, y)
    }

    private func sign(_ value: Double) -> Double {
        value > 0 ? 1 : (value < 0 ? -1 : 0)
    }
}
