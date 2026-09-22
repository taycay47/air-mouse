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
    /// Where the last tap ended, so a second one can be required to land near
    /// it. Without this any touch inside the window armed a drag, wherever on
    /// the surface it was.
    private var lastTapPoint: (x: Double, y: Double)?
    private var dragArmed = false
    private var dragDownSent = false
    private var dragHoldDeadline: Double?
    private var longPressDeadline: Double?
    private var longPressFired = false

    // Scroll state
    private enum EdgeScroll { case vertical, horizontal }
    private var edgeScroll: EdgeScroll?
    private var isTwoFingerScrolling = false

    /// The previous sample's midpoint, separation and time — kept apart from
    /// `lastScrollPoint`, which only advances when a pan is actually sent.
    private var lastSamplePoint: (x: Double, y: Double)?
    private var lastSpread: Double?
    private var lastTwoFingerSampleTime: Double?
    /// Recent motion, as leaky sums over `pinchEvidenceWindow`: how much the
    /// separation has been changing, and how far the midpoint has travelled.
    private var recentSpread: Double = 0
    private var recentMidpointTravel: Double = 0
    /// Signed spread gathered only while spreading dominates. Switching to
    /// zoom fires when it is large enough.
    private var pinchEvidence: Double = 0
    /// Midpoint travel gathered only while travelling dominates, during a
    /// zoom. Switching back to pan fires when it is large enough.
    private var panEvidence: Double = 0
    /// While zooming: the separation the last zoom step was measured from.
    private var zoomAnchorSpread: Double = 0
    /// Which of the two the gesture is doing right now.
    private var zooming = false
    /// Whether it zoomed at any point — which rules out ending as a right click
    /// even if it finished as a pan.
    private var zoomUsed = false
    private var lastScrollPoint: (x: Double, y: Double)?
    private var scrollVelocityX: Double = 0
    private var scrollVelocityY: Double = 0
    private var momentumVelocityX: Double = 0
    private var momentumVelocityY: Double = 0
    private var momentumActive = false

    /// Timestamps, so every velocity is measured against elapsed time rather
    /// than against "one event" — which is no longer a fixed amount of time.
    private var lastScrollTime: Double?
    private var lastMoveTime: Double?
    private var lastTickTime: Double?
    /// Smoothed pointer speed, in points per reference frame. Only the
    /// acceleration *factor* is filtered; the delta sent to the Mac is always
    /// the exact distance the finger moved, so smoothing costs no positional
    /// lag.
    private var pointerSpeed: Double = 0
    /// Whether the filters hold a real measurement yet.
    ///
    /// A filter starting from zero spends its first few samples climbing, which
    /// damps the beginning of every gesture — and a flick *is* its beginning:
    /// four or five samples, of which the first two would be throttled. The
    /// first sample of a gesture is taken as truth instead, and only later ones
    /// are smoothed.
    private var pointerSpeedPrimed = false
    private var scrollVelocityPrimed = false

    // Three fingers
    /// Set when a third finger lands, and held until every finger has lifted —
    /// fingers leave one at a time, and dropping back to a two-finger pan as
    /// the first one lifts would scroll whatever was under the cursor.
    private var isThreeFinger = false
    private var threeFingerStart: (x: Double, y: Double)?
    /// One gesture, one action.
    private var threeFingerFired = false

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

        if all.count >= 3 || isThreeFinger {
            cancelLongPress()
            cancelDragHold()
            // A two-finger pan in progress becomes a three-finger gesture the
            // moment the third finger lands.
            isTwoFingerScrolling = false
            isMoving = false
            if !isThreeFinger {
                isThreeFinger = true
                threeFingerFired = false
            }
            // Re-anchored on every landing, so a finger arriving late does not
            // register as the whole group having moved.
            threeFingerStart = midpoint(of: all)
            return effects
        }

        if all.count >= 2 {
            cancelLongPress()
            cancelDragHold()
            isTwoFingerScrolling = true
            isMoving = false
            lastScrollPoint = midpoint(of: all)
            // Reset with the point, not just alongside it: a stale timestamp
            // makes the first delta of a new gesture look like it took a very
            // long time, and the velocity it implies is wrong by whatever the
            // gap happened to be.
            lastScrollTime = time
            scrollVelocityX = 0
            scrollVelocityY = 0
            scrollVelocityPrimed = false
            lastSamplePoint = midpoint(of: all)
            lastSpread = spread(of: all)
            lastTwoFingerSampleTime = time
            recentSpread = 0
            recentMidpointTravel = 0
            pinchEvidence = 0
            panEvidence = 0
            zooming = false
            zoomUsed = false
            startTime = time
            return effects
        }

        guard let touch = touches.first else { return effects }
        startPoint = (touch.x, touch.y)
        lastPoint = (touch.x, touch.y)
        lastMoveTime = time
        pointerSpeed = 0
        pointerSpeedPrimed = false
        startTime = time
        longPressFired = false
        edgeScroll = nil

        if touch.x > surfaceWidth * (1 - config.rightEdgeFraction) {
            // The right strip scrolls, and only scrolls. It used to switch
            // desktop too, on a sideways component of 40pt — which a diagonal
            // scroll reaches easily.
            edgeScroll = .vertical
            isMoving = false
            lastScrollPoint = (touch.x, touch.y)
            lastScrollTime = time
            scrollVelocityY = 0
            scrollVelocityPrimed = false
            effects.append(.haptic(.edgeEnter))
        } else if touch.y > surfaceHeight * (1 - config.bottomEdgeFraction) {
            edgeScroll = .horizontal
            isMoving = false
            lastScrollPoint = (touch.x, touch.y)
            lastScrollTime = time
            scrollVelocityX = 0
            effects.append(.haptic(.edgeEnter))
        } else {
            isMoving = true
            if wasLastTouchTap,
               time - lastTouchEndTime < config.doubleTapWindow,
               let tapped = lastTapPoint,
               hypot(touch.x - tapped.x, touch.y - tapped.y) <= config.doubleTapMaxDistance {
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

        if isThreeFinger {
            // Judged only while all three are down. As they lift one at a time
            // the midpoint of the remainder jumps, and that jump is not a swipe.
            guard all.count >= 3, !threeFingerFired, let start = threeFingerStart else {
                return effects
            }
            let point = midpoint(of: all)
            let dx = point.x - start.x
            let dy = point.y - start.y
            guard max(abs(dx), abs(dy)) >= config.threeFingerSwipeDistance else { return effects }

            threeFingerFired = true
            if abs(dx) > abs(dy) {
                // As on a trackpad, the desktops follow the fingers: swiping
                // left brings in the one on the right.
                effects.append(.send(.switchDesktop(direction: dx < 0 ? .right : .left)))
            } else if dy < 0 {
                effects.append(.send(.key(code: "missioncontrol", modifiers: [])))
            } else {
                effects.append(.send(.key(code: "appexpose", modifiers: [])))
            }
            effects.append(.haptic(.desktopSwitch))
            return effects
        }

        if isTwoFingerScrolling, all.count >= 2 {
            let point = midpoint(of: all)
            let currentSpread = spread(of: all)

            // This sample's motion, against the previous *sample* — the
            // evidence has to see every step, including the ones too small to
            // send.
            let previousPoint = lastSamplePoint ?? point
            let previousSpread = lastSpread ?? currentSpread
            let seconds = max(time - (lastTwoFingerSampleTime ?? time), 0)
            lastSamplePoint = point
            lastSpread = currentSpread
            lastTwoFingerSampleTime = time

            let stepSpread = currentSpread - previousSpread
            let stepTravel = hypot(point.x - previousPoint.x, point.y - previousPoint.y)
            let keep = exp(-seconds / config.pinchEvidenceWindow)
            recentSpread = recentSpread * keep + stepSpread
            recentMidpointTravel = recentMidpointTravel * keep + stepTravel

            if zooming {
                // Pan wins as soon as the pair is clearly travelling together,
                // whether or not the separation is also changing: both at once
                // cannot be done, and moving the view is the one people notice
                // failing.
                if recentMidpointTravel >= abs(recentSpread) * config.panReclaimRatio {
                    panEvidence += stepTravel
                } else {
                    panEvidence *= keep
                }
                if panEvidence >= config.panReclaimDistance {
                    zooming = false
                    panEvidence = 0
                    pinchEvidence = 0
                    // Pick the pan up from the previous sample, so this step's
                    // travel is panned rather than lost, and with a fresh
                    // velocity rather than one left over from before the zoom.
                    lastScrollPoint = previousPoint
                    lastScrollTime = time - seconds
                    scrollVelocityPrimed = false
                }
            } else {
                if abs(recentSpread) > recentMidpointTravel * config.pinchDominance {
                    pinchEvidence += stepSpread
                } else {
                    // Translating, not spreading: whatever looked like a pinch
                    // was the hand drifting, and it fades rather than piling up
                    // across a long pan until it trips the threshold.
                    pinchEvidence *= keep
                }
                if abs(pinchEvidence) >= config.pinchActivationDistance {
                    zooming = true
                    zoomUsed = true
                    pinchEvidence = 0
                    panEvidence = 0
                    // Measured from the previous sample, so the step that
                    // settled it is still acted on — but not the evidence
                    // before it, which would land as one jump.
                    zoomAnchorSpread = previousSpread
                }
            }

            if zooming {
                let change = currentSpread - zoomAnchorSpread
                // Below the deadzone the anchor stays put, so slow pinching
                // accumulates instead of being discarded step by step.
                guard abs(change) > config.pinchDeadzone else { return effects }
                zoomAnchorSpread = currentSpread
                // Linear, with no acceleration curve: a pinch is direct
                // manipulation, and a curve between the fingers and the canvas
                // is felt as the canvas slipping.
                let direction: Double = config.pinchZoomInverted ? -1 : 1
                effects.append(.send(.scroll(
                    dx: 0,
                    dy: change * config.pinchZoomScale * direction,
                    modifiers: [.cmd])))
                return effects
            }

            guard let last = lastScrollPoint else {
                lastScrollPoint = point
                return effects
            }
            let rawX = point.x - last.x
            let rawY = point.y - last.y
            // The point only advances when something is sent. It used to
            // advance every sample, so a movement smaller than the deadzone was
            // not deferred but *lost* — and at 120Hz a slow pan is made almost
            // entirely of such movements.
            guard abs(rawX) > config.scrollDeadzone || abs(rawY) > config.scrollDeadzone else { return effects }
            lastScrollPoint = point
            effects += smoothedScroll(rawX: rawX, rawY: rawY,
                                      scale: config.twoFingerScrollScale,
                                      detentAbove: 6, at: time)
            return effects
        }

        guard let touch = touches.first else { return effects }

        if let edge = edgeScroll, let last = lastScrollPoint {
            switch edge {
            case .vertical:
                let raw = touch.y - last.y
                // Deferred, not discarded: see the two-finger path.
                guard abs(raw) > config.scrollDeadzone else { return effects }
                lastScrollPoint = (touch.x, touch.y)
                effects += smoothedScroll(rawX: 0, rawY: raw,
                                          scale: config.edgeScrollScale,
                                          detentAbove: 5, at: time)
            case .horizontal:
                let raw = touch.x - last.x
                guard abs(raw) > config.scrollDeadzone else { return effects }
                lastScrollPoint = (touch.x, touch.y)
                effects += smoothedScroll(rawX: raw, rawY: 0,
                                          scale: config.edgeScrollScale,
                                          detentAbove: 5, at: time)
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

        let seconds = max(time - (lastMoveTime ?? time), 0)
        let elapsed = frames(from: lastMoveTime, to: time)
        lastMoveTime = time
        // The factor is smoothed, the delta never is. Filtering position would
        // add lag to the one thing that must not have any.
        settle(&pointerSpeed, primed: &pointerSpeedPrimed,
               toward: hypot(dx, dy) / elapsed,
               seconds: seconds, tau: config.pointerVelocityTau)
        let factor = config.accelerationFactor(forSpeed: pointerSpeed)
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

        if isThreeFinger {
            // No click of any kind comes out of a three-finger gesture — not
            // the two-finger right click, not a tap as the last finger lifts.
            if remaining.isEmpty {
                reset()
                wasLastTouchTap = false
            }
            return effects
        }

        if isTwoFingerScrolling {
            // Two fingers down and up quickly, without scrolling anywhere, is a
            // right click — the trackpad convention.
            // A zoom is never also a right click, however briefly it lasted:
            // it leaves the scroll velocities at zero, which is exactly what
            // the tap test looks for.
            if !zoomUsed,
               duration < config.twoFingerTapMaxDuration,
               abs(scrollVelocityX) < 1, abs(scrollVelocityY) < 1 {
                effects.append(.send(.click(button: .right, action: .tap)))
                effects.append(.haptic(.rightClick))
            }
            if remaining.isEmpty {
                // Panning momentum only. A zoom that kept going after the
                // fingers left would be a zoom nobody asked for, and a gesture
                // that was mostly zoom has almost no midpoint velocity to hand
                // over anyway.
                if !zooming { effects += handOffToMomentum() }
                reset()
            }
            return effects
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
            lastTapPoint = (touch.x, touch.y)
        } else {
            wasLastTouchTap = false
            lastTapPoint = nil
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
            // Friction per unit time, not per tick. Applied per tick it decayed
            // twice as fast the moment the display link went to 120Hz.
            let elapsed = frames(from: lastTickTime, to: time)
            momentumVelocityX *= pow(config.momentumFriction, elapsed)
            momentumVelocityY *= pow(config.momentumFriction, elapsed)
            if abs(momentumVelocityX) < config.momentumStopVelocity,
               abs(momentumVelocityY) < config.momentumStopVelocity {
                momentumActive = false
            } else {
                // Velocity times the time it applied for — the same distance
                // in the same interval however often this is called.
                effects.append(.send(.scroll(
                    dx: momentumVelocityX * elapsed
                        * config.scrollFactor(forSpeed: abs(momentumVelocityX))
                        * config.twoFingerScrollScale,
                    dy: momentumVelocityY * elapsed
                        * config.scrollFactor(forSpeed: abs(momentumVelocityY))
                        * config.twoFingerScrollScale)))
            }
        }
        lastTickTime = time

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

    private func smoothedScroll(rawX: Double, rawY: Double, scale: Double,
                                detentAbove: Double, at time: Double) -> [GestureEffect] {
        let seconds = max(time - (lastScrollTime ?? time), 0)
        let elapsed = frames(from: lastScrollTime, to: time)
        lastScrollTime = time

        // Velocity in points per reference frame, so the curve's thresholds
        // mean what they meant when they were tuned — whatever rate the
        // samples are actually arriving at.
        var primed = scrollVelocityPrimed
        settle(&scrollVelocityX, primed: &primed, toward: rawX / elapsed,
               seconds: seconds, tau: config.scrollVelocityTau)
        primed = scrollVelocityPrimed
        settle(&scrollVelocityY, primed: &primed, toward: rawY / elapsed,
               seconds: seconds, tau: config.scrollVelocityTau)
        scrollVelocityPrimed = true

        let speedX = abs(scrollVelocityX)
        let speedY = abs(scrollVelocityY)

        // Distance times acceleration, not a fixed step in the direction of
        // travel: how far the finger went is the thing being scaled.
        var effects: [GestureEffect] = [.send(.scroll(
            dx: rawX * config.scrollFactor(forSpeed: speedX) * scale,
            dy: rawY * config.scrollFactor(forSpeed: speedY) * scale))]
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
        isThreeFinger = false
        threeFingerStart = nil
        threeFingerFired = false
        dragArmed = false
        startPoint = nil
        lastPoint = nil
        lastScrollPoint = nil
        lastScrollTime = nil
        lastMoveTime = nil
        pointerSpeedPrimed = false
        scrollVelocityPrimed = false
        lastSamplePoint = nil
        lastSpread = nil
        lastTwoFingerSampleTime = nil
        recentSpread = 0
        recentMidpointTravel = 0
        pinchEvidence = 0
        panEvidence = 0
        zooming = false
        zoomUsed = false
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

    /// Distance between the two fingers furthest apart.
    private func spread(of touches: [Touch]) -> Double {
        guard touches.count >= 2 else { return 0 }
        return hypot(touches[0].x - touches[1].x, touches[0].y - touches[1].y)
    }

    private func sign(_ value: Double) -> Double {
        value > 0 ? 1 : (value < 0 ? -1 : 0)
    }

    /// Elapsed time expressed in reference frames, clamped.
    ///
    /// The clamp matters at both ends: a coalesced sample can arrive a fraction
    /// of a millisecond after the last one, and dividing by that turns touch
    /// quantisation into an enormous velocity; a gesture resumed after a stall
    /// would otherwise report a velocity of nearly zero.
    private func frames(from last: Double?, to now: Double) -> Double {
        guard let last, now > last else { return 1 }
        let elapsed = (now - last) * GestureConfig.referenceFrameRate
        return min(max(elapsed, 0.15), 4)
    }

    /// One step of a low-pass whose window is fixed in *time*, not in samples.
    private func settle(_ value: inout Double, primed: inout Bool,
                        toward target: Double, seconds: Double, tau: Double) {
        guard primed else {
            value = target
            primed = true
            return
        }
        let alpha = 1 - exp(-max(seconds, 0) / tau)
        value += (target - value) * alpha
    }
}
