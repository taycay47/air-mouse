import XCTest
import AirMouseProtocol
@testable import AirMouseGestures

/// The gesture layer is the product — the wire protocol is trivial by
/// comparison. These tests exist so the tuning can be refactored without
/// silently changing how the thing feels, which is exactly what happens when
/// the only test is someone waving a phone around.
final class GestureEngineTests: XCTestCase {

    private func makeEngine() -> GestureEngine {
        GestureEngine(surfaceWidth: 400, surfaceHeight: 800)
    }

    /// Centre of the surface, well away from every edge strip.
    private func touch(_ x: Double = 200, _ y: Double = 400, id: Int = 1) -> Touch {
        Touch(id: id, x: x, y: y)
    }

    private func messages(_ effects: [GestureEffect]) -> [ClientMessage] {
        effects.compactMap { if case .send(let m) = $0 { return m } else { return nil } }
    }

    private func haptics(_ effects: [GestureEffect]) -> [HapticCue] {
        effects.compactMap { if case .haptic(let h) = $0 { return h } else { return nil } }
    }

    // MARK: - Curves

    func testPointerAccelerationDampensSlowMovement() {
        let config = GestureConfig()
        // Below 2px/frame the pointer is damped, not 1:1. Precision work lives
        // here and 1:1 feels twitchy on a surface this small.
        XCTAssertEqual(config.accelerationFactor(forSpeed: 0), 0.45, accuracy: 0.0001)
        XCTAssertEqual(config.accelerationFactor(forSpeed: 1), 0.725, accuracy: 0.0001)
        XCTAssertEqual(config.accelerationFactor(forSpeed: 2), 1.0, accuracy: 0.0001)
    }

    func testPointerAccelerationGrowsAboveTheThreshold() {
        let config = GestureConfig()
        XCTAssertGreaterThan(config.accelerationFactor(forSpeed: 10), 1.0)
        // Monotonic: a faster flick must never move the cursor less far.
        var previous = 0.0
        for speed in stride(from: 0.0, through: 40.0, by: 0.5) {
            let travel = speed * config.accelerationFactor(forSpeed: speed)
            XCTAssertGreaterThanOrEqual(travel, previous)
            previous = travel
        }
    }

    /// The scroll curve is an S: flat at both ends, steepest in the middle.
    ///
    /// Flat at the bottom is precision — a slow drag places a long document
    /// exactly. Flat at the top is restraint — the old curve grew without
    /// bound, so flicking harder always scrolled further and the high end ran
    /// away. The middle is where the response lives.
    func testScrollCurveIsAnS() {
        let config = GestureConfig()

        // Ends, pinned to the configured floor and ceiling.
        XCTAssertEqual(config.scrollFactor(forSpeed: 0), config.scrollMinGain, accuracy: 0.0001)
        XCTAssertEqual(config.scrollFactor(forSpeed: config.scrollFullSpeed),
                       config.scrollMaxGain, accuracy: 0.0001)
        // Bounded past the end, where the old curve kept climbing.
        XCTAssertEqual(config.scrollFactor(forSpeed: 500),
                       config.scrollMaxGain, accuracy: 0.0001)

        // Monotonic throughout: no speed scrolls less than a slower one.
        var previous = -Double.infinity
        for step in 0...80 {
            let factor = config.scrollFactor(forSpeed: Double(step) * 0.25)
            XCTAssertGreaterThanOrEqual(factor, previous)
            previous = factor
        }

        // The S itself: the middle must be steeper than either end.
        func slope(around speed: Double) -> Double {
            (config.scrollFactor(forSpeed: speed + 0.25)
                - config.scrollFactor(forSpeed: speed - 0.25)) / 0.5
        }
        let middle = slope(around: config.scrollFullSpeed / 2)
        XCTAssertGreaterThan(middle, slope(around: config.scrollFullSpeed * 0.05) * 3,
                             "the low end must be far flatter than the middle")
        XCTAssertGreaterThan(middle, slope(around: config.scrollFullSpeed * 0.95) * 3,
                             "the high end must be far flatter than the middle")
    }

    // MARK: - Tap

    func testQuickShortTouchIsATap() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        let effects = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        XCTAssertEqual(messages(effects), [.click(button: .left, action: .tap)])
        XCTAssertEqual(haptics(effects), [.tap])
    }

    func testSlowTouchIsNotATap() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        // Held past tapMaxDuration: the user was positioning, not clicking.
        let effects = engine.touchesEnded([touch()], remaining: [], at: 0.3)
        XCTAssertTrue(messages(effects).isEmpty)
    }

    func testTouchThatTravelledIsNotATap() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesMoved([touch(240, 400)], all: [touch(240, 400)], at: 0.05)
        let effects = engine.touchesEnded([touch(240, 400)], remaining: [], at: 0.1)
        XCTAssertTrue(messages(effects).isEmpty)
    }

    // MARK: - Long press

    func testHoldingStillFiresARightClick() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        XCTAssertTrue(messages(engine.tick(at: 0.4)).isEmpty, "not yet")
        let effects = engine.tick(at: 0.51)
        XCTAssertEqual(messages(effects), [.click(button: .right, action: .tap)])
    }

    func testDriftingCancelsTheRightClick() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesMoved([touch(215, 400)], all: [touch(215, 400)], at: 0.1)
        XCTAssertTrue(messages(engine.tick(at: 0.6)).isEmpty,
                      "drift beyond the slop must cancel a pending right click")
    }

    func testRightClickSuppressesTheTapOnRelease() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.tick(at: 0.51)
        let effects = engine.touchesEnded([touch()], remaining: [], at: 0.6)
        XCTAssertTrue(messages(effects).isEmpty, "a long press must not also click")
    }

    // MARK: - Drag

    func testDoubleTapThenHoldPicksUpADrag() {
        let engine = makeEngine()
        // First tap.
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        // Second touch, inside the double-tap window.
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        let effects = engine.tick(at: 0.2 + GestureConfig().dragHoldDuration + 0.01)
        XCTAssertEqual(messages(effects), [.click(button: .left, action: .down)])
        XCTAssertTrue(engine.isButtonHeld)
    }

    func testDoubleTapThenMovePicksUpADragSooner() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        // Past dragActivateDistance, which is deliberately not a small number:
        // the second touch of a double tap is often already sliding as it
        // lands, and treating a few points of that as intent is how moving the
        // cursor became dragging whatever was under it.
        let far = 200 + GestureConfig().dragActivateDistance + 2
        let effects = engine.touchesMoved([touch(far, 400)], all: [touch(far, 400)], at: 0.22)
        XCTAssertTrue(messages(effects).contains(.click(button: .left, action: .down)))
    }

    /// A second tap somewhere else is not a double tap.
    ///
    /// There was no distance test at all, so tapping, then reaching across the
    /// surface and moving, picked up whatever was under the cursor and carried
    /// it — which is the single easiest way to disturb a document by accident.
    func testASecondTapFarAwayDoesNotArmADrag() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)

        let away = 200 + GestureConfig().doubleTapMaxDistance + 20
        _ = engine.touchesBegan([touch(away, 400)], all: [touch(away, 400)], at: 0.2)
        let effects = engine.touchesMoved([touch(away + 40, 400)], all: [touch(away + 40, 400)],
                                          at: 0.22)

        XCTAssertFalse(messages(effects).contains(.click(button: .left, action: .down)),
                       "a tap in one place and a drag in another is not a double tap")
        XCTAssertFalse(engine.isButtonHeld)
    }

    func testPointerDoesNotJumpWhenADragIsArmedButUncommitted() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        // Under the activation distance: the finger is tracked but nothing is
        // sent, otherwise the cursor leaps when the button finally goes down.
        let effects = engine.touchesMoved([touch(203, 400)], all: [touch(203, 400)], at: 0.21)
        XCTAssertTrue(messages(effects).isEmpty)
    }

    func testDoubleTapWithoutHoldingIsADoubleClick() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        let effects = engine.touchesEnded([touch()], remaining: [], at: 0.25)
        XCTAssertEqual(messages(effects), [.click(button: .left, action: .doubleTap)])
    }

    func testSecondTapOutsideTheWindowIsJustAnotherTap() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.9)
        let effects = engine.touchesEnded([touch()], remaining: [], at: 0.95)
        XCTAssertEqual(messages(effects), [.click(button: .left, action: .tap)])
    }

    // MARK: - Held buttons are always released (ADR-0006)

    func testCancelReleasesAHeldButton() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        // Past the hold threshold, read from the config rather than written
        // in: it has changed once already, and a guarantee about releasing
        // held buttons should not break because a timing was retuned.
        _ = engine.tick(at: 0.2 + GestureConfig().dragHoldDuration + 0.01)
        XCTAssertTrue(engine.isButtonHeld)

        // The call arrives, the notification lands, the system takes the touch.
        let effects = engine.touchesCancelled(at: 0.8)
        XCTAssertEqual(messages(effects), [.click(button: .left, action: .up)])
        XCTAssertFalse(engine.isButtonHeld)
    }

    func testReleaseEverythingIsSafeWhenNothingIsHeld() {
        let engine = makeEngine()
        XCTAssertTrue(engine.releaseEverything().isEmpty)
    }

    func testDragEndsWithAReleaseOnNormalLift() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        // Past the hold threshold, read from the config rather than written
        // in: it has changed once already, and a guarantee about releasing
        // held buttons should not break because a timing was retuned.
        _ = engine.tick(at: 0.2 + GestureConfig().dragHoldDuration + 0.01)
        let effects = engine.touchesEnded([touch()], remaining: [], at: 0.8)
        XCTAssertEqual(messages(effects), [.click(button: .left, action: .up)])
        XCTAssertFalse(engine.isButtonHeld)
    }

    // MARK: - Scrolling

    func testTwoFingersScroll() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)
        let moved = [touch(180, 380, id: 1), touch(220, 380, id: 2)]
        let effects = engine.touchesMoved(moved, all: moved, at: 0.02)
        guard case .scroll(let dx, let dy, _)? = messages(effects).first else {
            return XCTFail("expected a scroll, got \(messages(effects))")
        }
        XCTAssertEqual(dx, 0, accuracy: 0.0001)
        XCTAssertLessThan(dy, 0, "moving fingers up must scroll up")
    }

    // MARK: - Pinch to zoom

    /// Fingers moving apart zoom, and they do it as ⌘-scroll — which is what
    /// Figma, Canva and browsers actually listen for. A real magnify event
    /// cannot be posted with public API.
    func testSpreadingFingersSendsCommandScroll() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)
        // Apart, in opposite directions, midpoint unmoved.
        let spread = [touch(170, 400, id: 1), touch(230, 400, id: 2)]
        let effects = engine.touchesMoved(spread, all: spread, at: 0.02)

        guard case .scroll(let dx, let dy, let modifiers)? = messages(effects).first else {
            return XCTFail("expected a scroll, got \(messages(effects))")
        }
        XCTAssertEqual(modifiers, [.cmd], "zoom is ⌘-scroll or it is nothing")
        XCTAssertEqual(dx, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(dy, 0, "spreading fingers must zoom in")
    }

    func testPinchingInZoomsTheOtherWay() {
        let engine = makeEngine()
        let pair = [touch(170, 400, id: 1), touch(230, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)
        let pinched = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        let effects = engine.touchesMoved(pinched, all: pinched, at: 0.02)

        guard case .scroll(_, let dy, let modifiers)? = messages(effects).first else {
            return XCTFail("expected a scroll, got \(messages(effects))")
        }
        XCTAssertEqual(modifiers, [.cmd])
        XCTAssertLessThan(dy, 0)
    }

    /// The discrimination that matters: two fingers travelling together are a
    /// scroll however far apart they happen to drift, and must never arrive as
    /// a zoom.
    func testFingersMovingTogetherNeverZoom() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)

        var sent: [ClientMessage] = []
        for step in 1...6 {
            // Same direction, with a point of drift between them each step.
            let y = 400 - 6 * Double(step)
            let moved = [touch(180, y, id: 1), touch(220 + Double(step), y, id: 2)]
            sent += messages(engine.touchesMoved(moved, all: moved, at: 0.016 * Double(step)))
        }

        XCTAssertFalse(sent.isEmpty, "a two-finger drag must send something")
        for message in sent {
            guard case .scroll(_, _, let modifiers) = message else {
                return XCTFail("expected only scrolls, got \(message)")
            }
            XCTAssertTrue(modifiers.isEmpty, "a scroll must not arrive as a zoom")
        }
    }

    /// A two-finger gesture starts as a pan and is promoted to a zoom.
    ///
    /// The earlier classifier decided within the first few points, so settling
    /// your hand before a pinch locked the whole gesture into panning. Now the
    /// pan is live immediately and the zoom takes over whenever the fingers
    /// actually change their separation — however late that is.
    func testPanningPromotesToZoomWhenTheFingersSpread() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)

        // Both fingers travel together: a pan, separation unchanged.
        var panned: [ClientMessage] = []
        for step in 1...3 {
            let y = 400 - 8 * Double(step)
            let moved = [touch(180, y, id: 1), touch(220, y, id: 2)]
            panned += messages(engine.touchesMoved(moved, all: moved, at: 0.016 * Double(step)))
        }
        XCTAssertFalse(panned.isEmpty, "panning must work from the start")
        for message in panned {
            guard case .scroll(_, _, let modifiers) = message else {
                return XCTFail("expected scrolls while panning, got \(message)")
            }
            XCTAssertTrue(modifiers.isEmpty, "panning is not zooming")
        }

        // Now spread them, well past the activation distance.
        let spread = [touch(150, 376, id: 1), touch(250, 376, id: 2)]
        let zoomed = messages(engine.touchesMoved(spread, all: spread, at: 0.064))
        guard case .scroll(_, _, let modifiers)? = zoomed.first else {
            return XCTFail("expected a zoom, got \(zoomed)")
        }
        XCTAssertEqual(modifiers, [.cmd], "spreading must promote the gesture to a zoom")

        // Then move the pair together, separation held: that is a pan again.
        // Being mid-pinch does not trap you there.
        var after: [ClientMessage] = []
        for step in 1...3 {
            let y = 376 - 12 * Double(step)
            let moved = [touch(150, y, id: 1), touch(250, y, id: 2)]
            after += messages(engine.touchesMoved(moved, all: moved, at: 0.064 + 0.016 * Double(step)))
        }
        let afterModifiers = after.compactMap { message -> [KeyModifier]? in
            if case .scroll(_, _, let mods) = message { return mods } else { return nil }
        }
        XCTAssertTrue(afterModifiers.contains([]), "moving the fingers together must pan again")
        XCTAssertEqual(afterModifiers.last ?? [.cmd], [], "and keep panning once it has switched back")
    }

    /// Both at once is a pan.
    ///
    /// ⌘-scroll reinterprets a scroll rather than adding zoom to it, so the two
    /// cannot run together and one has to win. Panning does: moving the view is
    /// the failure people notice.
    func testPanningWinsWhenTheFingersAlsoSpread() {
        let engine = makeEngine()
        let pair = [touch(180, 600, id: 1), touch(220, 600, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)

        var sent: [ClientMessage] = []
        for step in 1...20 {
            // Travelling 10pt a frame together while opening 6pt a frame.
            let y = 600 - 10 * Double(step)
            let open = 3 * Double(step)
            let moved = [touch(180 - open, y, id: 1), touch(220 + open, y, id: 2)]
            sent += messages(engine.touchesMoved(moved, all: moved, at: Double(step) / 60))
        }
        for message in sent {
            guard case .scroll(_, _, let modifiers) = message else { continue }
            XCTAssertTrue(modifiers.isEmpty, "when both happen, panning must win")
        }
    }

    /// A pinch with one finger held still is still a pinch.
    ///
    /// It moves the midpoint at half the rate the separation changes — which is
    /// motion, but not the pair travelling together — so it must neither fail
    /// to start a zoom nor be handed back to panning halfway.
    func testAPinchWithOneFingerStillStaysAZoom() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)

        var sent: [ClientMessage] = []
        for step in 1...20 {
            let moved = [touch(180, 400, id: 1), touch(220 + 5 * Double(step), 400, id: 2)]
            sent += messages(engine.touchesMoved(moved, all: moved, at: Double(step) / 60))
        }
        let modifiers = sent.compactMap { message -> [KeyModifier]? in
            if case .scroll(_, _, let mods) = message { return mods } else { return nil }
        }
        XCTAssertTrue(modifiers.contains([.cmd]), "a one-finger pinch must zoom")
        let firstZoom = modifiers.firstIndex(of: [.cmd]) ?? modifiers.count
        XCTAssertFalse(modifiers[firstZoom...].contains([]),
                       "once zooming, a one-finger pinch must not fall back to panning")
    }

    /// A long pan never turns into a zoom just because the hand rolls.
    ///
    /// No hand holds two fingers exactly apart across a long pan. The first
    /// version of promotion counted total change in separation, and a drift of
    /// well under a point per frame crossed the threshold a couple of hundred
    /// points into an ordinary pan — stopping it dead and starting a zoom. What
    /// matters is whether spreading *dominates* the motion, not how much has
    /// accumulated.
    func testALongPanWithDriftingFingersNeverZooms() {
        let engine = makeEngine()
        let pair = [touch(180, 700, id: 1), touch(220, 700, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)

        var sent: [ClientMessage] = []
        for step in 1...60 {
            // 10pt of travel per frame, with the separation creeping open by
            // 0.8pt per frame — 48pt of drift over the pan, four times what
            // used to trip promotion.
            let y = 700 - 10 * Double(step)
            let drift = 0.4 * Double(step)
            let moved = [touch(180 - drift, y, id: 1), touch(220 + drift, y, id: 2)]
            sent += messages(engine.touchesMoved(moved, all: moved, at: Double(step) / 60))
        }

        XCTAssertFalse(sent.isEmpty)
        for message in sent {
            guard case .scroll(_, _, let modifiers) = message else { continue }
            XCTAssertTrue(modifiers.isEmpty, "a pan must stay a pan however the hand rolls")
        }
    }

    /// Small movements are deferred, not thrown away.
    ///
    /// The pan point used to advance every sample, so a step under the deadzone
    /// was simply lost. At 120Hz a slow pan is made almost entirely of such
    /// steps, which is how a slow drag came to barely move.
    func testSlowPanningAccumulatesInsteadOfDisappearing() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)

        var sent: [ClientMessage] = []
        for step in 1...20 {
            // 0.2pt per sample: every single step is below the deadzone.
            let y = 400 - 0.2 * Double(step)
            let moved = [touch(180, y, id: 1), touch(220, y, id: 2)]
            sent += messages(engine.touchesMoved(moved, all: moved, at: Double(step) / 120))
        }
        XCTAssertFalse(sent.isEmpty,
                       "four points of deliberate movement must scroll something")
    }

    /// A pinch is not also a right click, even though it leaves the scroll
    /// velocities at zero — which is exactly what the tap test looks for.
    func testPinchDoesNotAlsoRightClick() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)
        let spread = [touch(170, 400, id: 1), touch(230, 400, id: 2)]
        _ = engine.touchesMoved(spread, all: spread, at: 0.02)
        let effects = engine.touchesEnded(spread, remaining: [], at: 0.05)

        for message in messages(effects) {
            if case .click(let button, _) = message, button == .right {
                XCTFail("a pinch must not end as a right click")
            }
        }
    }

    func testTwoFingerTapIsARightClick() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)
        let effects = engine.touchesEnded(pair, remaining: [], at: 0.1)
        XCTAssertEqual(messages(effects), [.click(button: .right, action: .tap)])
    }

    func testMomentumContinuesAfterReleaseAndDecays() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)
        // Several fast moves, to build velocity past the momentum threshold.
        for step in 1...5 {
            let y = 400.0 - Double(step) * 20
            let moved = [touch(180, y, id: 1), touch(220, y, id: 2)]
            _ = engine.touchesMoved(moved, all: moved, at: Double(step) * 0.016)
        }
        _ = engine.touchesEnded(pair, remaining: [], at: 0.1)

        let first = messages(engine.tick(at: 0.12))
        XCTAssertFalse(first.isEmpty, "momentum must keep scrolling after release")

        // And it must stop on its own rather than scrolling forever.
        var ticks = 0
        var time = 0.13
        while !messages(engine.tick(at: time)).isEmpty, ticks < 1000 {
            ticks += 1
            time += 0.016
        }
        XCTAssertLessThan(ticks, 1000, "momentum must decay to a stop")
    }

    func testNewTouchStopsMomentum() {
        let engine = makeEngine()
        let pair = [touch(180, 400, id: 1), touch(220, 400, id: 2)]
        _ = engine.touchesBegan(pair, all: pair, at: 0)
        for step in 1...5 {
            let y = 400.0 - Double(step) * 20
            let moved = [touch(180, y, id: 1), touch(220, y, id: 2)]
            _ = engine.touchesMoved(moved, all: moved, at: Double(step) * 0.016)
        }
        _ = engine.touchesEnded(pair, remaining: [], at: 0.1)
        XCTAssertFalse(messages(engine.tick(at: 0.12)).isEmpty)

        // Catching a moving list has to feel immediate.
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.13)
        XCTAssertTrue(messages(engine.tick(at: 0.14)).isEmpty)
    }

    // MARK: - Edges

    func testRightEdgeScrollsVertically() {
        let engine = makeEngine()
        // Inside the rightmost 10% of a 400pt surface.
        let start = touch(390, 400)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        let effects = engine.touchesMoved([touch(390, 380)], all: [touch(390, 380)], at: 0.02)
        guard case .scroll(let dx, let dy, _)? = messages(effects).first else {
            return XCTFail("expected a scroll, got \(messages(effects))")
        }
        XCTAssertEqual(dx, 0, accuracy: 0.0001)
        XCTAssertLessThan(dy, 0)
    }

    func testBottomEdgeScrollsHorizontally() {
        let engine = makeEngine()
        let start = touch(200, 790)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        let effects = engine.touchesMoved([touch(180, 790)], all: [touch(180, 790)], at: 0.02)
        guard case .scroll(let dx, let dy, _)? = messages(effects).first else {
            return XCTFail("expected a scroll, got \(messages(effects))")
        }
        XCTAssertEqual(dy, 0, accuracy: 0.0001)
        XCTAssertLessThan(dx, 0)
    }

    func testEdgeStripDoesNotMoveTheCursor() {
        let engine = makeEngine()
        let start = touch(390, 400)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        let effects = engine.touchesMoved([touch(390, 380)], all: [touch(390, 380)], at: 0.02)
        XCTAssertFalse(messages(effects).contains { if case .trackpad = $0 { return true } else { return false } })
    }

    // MARK: - Three fingers

    private func threeFingers(at x: Double, _ y: Double) -> [Touch] {
        [touch(x - 40, y, id: 1), touch(x, y, id: 2), touch(x + 40, y, id: 3)]
    }

    private func threeFingerSwipe(dx: Double, dy: Double) -> [ClientMessage] {
        let engine = makeEngine()
        let start = threeFingers(at: 200, 400)
        _ = engine.touchesBegan(start, all: start, at: 0)
        var sent: [ClientMessage] = []
        for step in 1...6 {
            let f = Double(step) / 6
            let moved = threeFingers(at: 200 + dx * f, 400 + dy * f)
            sent += messages(engine.touchesMoved(moved, all: moved, at: 0.016 * Double(step)))
        }
        sent += messages(engine.touchesEnded(threeFingers(at: 200 + dx, 400 + dy),
                                             remaining: [], at: 0.2))
        return sent
    }

    /// As on a trackpad, the desktops follow the fingers: swiping left brings
    /// in the desktop on the right.
    func testThreeFingerSwipeLeftBringsInTheDesktopOnTheRight() {
        XCTAssertEqual(threeFingerSwipe(dx: -120, dy: 0), [.switchDesktop(direction: .right)])
    }

    func testThreeFingerSwipeRightBringsInTheDesktopOnTheLeft() {
        XCTAssertEqual(threeFingerSwipe(dx: 120, dy: 0), [.switchDesktop(direction: .left)])
    }

    func testThreeFingersUpOpensMissionControl() {
        XCTAssertEqual(threeFingerSwipe(dx: 0, dy: -120),
                       [.key(code: "missioncontrol", modifiers: [])])
    }

    func testThreeFingersDownOpensAppExpose() {
        XCTAssertEqual(threeFingerSwipe(dx: 0, dy: 120),
                       [.key(code: "appexpose", modifiers: [])])
    }

    /// One gesture, one action — however far the fingers keep going, and with
    /// no click or scroll leaking out of it as they lift.
    func testAThreeFingerGestureFiresExactlyOnce() {
        XCTAssertEqual(threeFingerSwipe(dx: -300, dy: 0).count, 1)
    }

    func testAShortThreeFingerMovementDoesNothing() {
        XCTAssertTrue(threeFingerSwipe(dx: -20, dy: 0).isEmpty)
    }

    /// Fingers land one at a time. A two-finger pan already under way becomes
    /// a three-finger gesture when the third arrives, and lifting them one at
    /// a time afterwards must not produce a right click or a pan.
    func testFingersArrivingAndLeavingOneAtATimeStayAThreeFingerGesture() {
        let engine = makeEngine()
        let two = [touch(160, 400, id: 1), touch(200, 400, id: 2)]
        _ = engine.touchesBegan(two, all: two, at: 0)
        let three = threeFingers(at: 200, 400)
        _ = engine.touchesBegan([three[2]], all: three, at: 0.03)

        var sent: [ClientMessage] = []
        // Lift them one at a time; the remaining two move a little as they go.
        sent += messages(engine.touchesEnded([three[2]], remaining: Array(three[0...1]), at: 0.1))
        let drifting = [touch(160, 420, id: 1), touch(200, 420, id: 2)]
        sent += messages(engine.touchesMoved(drifting, all: drifting, at: 0.12))
        sent += messages(engine.touchesEnded([drifting[1]], remaining: [drifting[0]], at: 0.14))
        sent += messages(engine.touchesEnded([drifting[0]], remaining: [], at: 0.16))

        XCTAssertTrue(sent.isEmpty, "nothing may leak out of a three-finger gesture, got \(sent)")
    }

    // MARK: - The accidents

    /// The left edge is ordinary surface now.
    ///
    /// It used to be a strip, a thumb wide, where a one-finger sideways
    /// movement switched desktop and the cursor did not move at all — so
    /// reaching for that side of the screen to move the cursor found nothing
    /// happening, and then a desktop switch.
    func testTheLeftEdgeMovesTheCursorAndNeverSwitchesDesktop() {
        let engine = makeEngine()
        let start = touch(10, 400)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        var sent = messages(engine.touchesMoved([touch(90, 400)], all: [touch(90, 400)], at: 0.05))
        sent += messages(engine.touchesEnded([touch(90, 400)], remaining: [], at: 0.3))

        XCTAssertTrue(sent.contains { if case .trackpad = $0 { return true } else { return false } },
                      "the left edge must move the cursor like anywhere else")
        XCTAssertFalse(sent.contains { if case .switchDesktop = $0 { return true } else { return false } })
    }

    /// A diagonal scroll in the right-hand strip only scrolls.
    func testSidewaysDriftWhileEdgeScrollingNeverSwitchesDesktop() {
        let engine = makeEngine()
        let start = touch(390, 600)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        var sent: [ClientMessage] = []
        for step in 1...10 {
            let moved = touch(390 - 8 * Double(step), 600 - 20 * Double(step))
            sent += messages(engine.touchesMoved([moved], all: [moved], at: Double(step) / 60))
        }
        sent += messages(engine.touchesEnded([touch(310, 400)], remaining: [], at: 0.3))
        XCTAssertFalse(sent.contains { if case .switchDesktop = $0 { return true } else { return false } })
    }

    /// Putting a finger back down a moment after a click, to carry on moving
    /// the cursor, is not a double tap.
    func testASecondTouchAfterTheWindowDoesNotArmADrag() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)

        let late = 0.1 + GestureConfig().doubleTapWindow + 0.03
        _ = engine.touchesBegan([touch()], all: [touch()], at: late)
        var sent = messages(engine.tick(at: late + 0.5))
        sent += messages(engine.touchesMoved([touch(240, 400)], all: [touch(240, 400)], at: late + 0.52))

        XCTAssertFalse(sent.contains(.click(button: .left, action: .down)))
        XCTAssertFalse(engine.isButtonHeld)
    }

    /// Nor does a short rest before moving pick anything up.
    func testABriefRestAfterADoubleTapDoesNotPickUpADrag() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        // The old hold threshold was 140ms, shorter than a natural pause.
        let sent = messages(engine.tick(at: 0.2 + 0.15))
        XCTAssertFalse(sent.contains(.click(button: .left, action: .down)))
    }

    // MARK: - Pointer

    func testMovementSendsAcceleratedDeltas() {
        let engine = makeEngine()
        // Exactly one reference frame, so ten points of travel is a speed of
        // ten. Speed is measured against elapsed time now, so the difference
        // between 0.016 and a real 1/60 frame is no longer beneath notice.
        let frame = 1.0 / GestureConfig.referenceFrameRate
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        let effects = engine.touchesMoved([touch(210, 400)], all: [touch(210, 400)], at: frame)
        guard case .trackpad(let dx, let dy)? = messages(effects).first else {
            return XCTFail("expected a trackpad move, got \(messages(effects))")
        }
        let config = GestureConfig()
        XCTAssertEqual(dx, 10 * config.baseSensitivity * config.accelerationFactor(forSpeed: 10),
                       accuracy: 0.0001)
        XCTAssertEqual(dy, 0, accuracy: 0.0001)
    }

    /// The first movement of a gesture gets its full acceleration.
    ///
    /// The velocity filter is primed from its first sample rather than climbing
    /// out of zero. A flick *is* its first few samples, so a filter warming up
    /// across them throttles exactly the gesture that wants amplifying.
    func testFirstMovementIsNotDampedByTheFilter() {
        let engine = makeEngine()
        let frame = 1.0 / GestureConfig.referenceFrameRate
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        let effects = engine.touchesMoved([touch(212, 400)], all: [touch(212, 400)], at: frame)
        guard case .trackpad(let dx, _)? = messages(effects).first else {
            return XCTFail("expected a trackpad move")
        }
        let config = GestureConfig()
        XCTAssertEqual(dx, 12 * config.baseSensitivity * config.accelerationFactor(forSpeed: 12),
                       accuracy: 0.0001)
    }

    // MARK: - Independence from the sample rate
    //
    // Coalesced touches deliver up to four samples a frame and the display link
    // runs at 120Hz, so "one event" is not a fixed amount of time and never will
    // be again. The same gesture, delivered at any rate, must move the cursor
    // the same distance — measuring speed per event rather than per second
    // silently collapsed the acceleration curve's range into its flat zone.

    func testPointerTravelIsIndependentOfSampleRate() {
        let frame = 1.0 / GestureConfig.referenceFrameRate

        let coarse = makeEngine()
        _ = coarse.touchesBegan([touch()], all: [touch()], at: 0)
        let single = messages(coarse.touchesMoved([touch(212, 400)], all: [touch(212, 400)], at: frame))

        let fine = makeEngine()
        _ = fine.touchesBegan([touch()], all: [touch()], at: 0)
        var split: [ClientMessage] = []
        for step in 1...4 {
            let x = 200 + 3 * Double(step)
            split += messages(fine.touchesMoved([touch(x, 400)], all: [touch(x, 400)],
                                                at: frame * Double(step) / 4))
        }

        func totalDX(_ messages: [ClientMessage]) -> Double {
            messages.reduce(0) { sum, message in
                if case .trackpad(let dx, _) = message { return sum + dx }
                return sum
            }
        }
        XCTAssertEqual(totalDX(split), totalDX(single), accuracy: 0.0001)
    }

    func testScrollTravelIsIndependentOfSampleRate() {
        let frame = 1.0 / GestureConfig.referenceFrameRate
        // The right-hand strip, which scrolls vertically.
        let x = 390.0

        let coarse = makeEngine()
        _ = coarse.touchesBegan([touch(x, 400)], all: [touch(x, 400)], at: 0)
        let single = messages(coarse.touchesMoved([touch(x, 412)], all: [touch(x, 412)], at: frame))

        let fine = makeEngine()
        _ = fine.touchesBegan([touch(x, 400)], all: [touch(x, 400)], at: 0)
        var split: [ClientMessage] = []
        for step in 1...4 {
            let y = 400 + 3 * Double(step)
            split += messages(fine.touchesMoved([touch(x, y)], all: [touch(x, y)],
                                                at: frame * Double(step) / 4))
        }

        func totalDY(_ messages: [ClientMessage]) -> Double {
            messages.reduce(0) { sum, message in
                if case .scroll(_, let dy, _) = message { return sum + dy }
                return sum
            }
        }
        XCTAssertEqual(totalDY(split), totalDY(single), accuracy: 0.0001)
    }
}
