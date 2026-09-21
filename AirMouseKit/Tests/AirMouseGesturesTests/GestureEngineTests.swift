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

    func testScrollFactorHasAFlatZone() {
        let config = GestureConfig()
        // Scrolling has a rhythm that acceleration disrupts, so 1.5–3px/frame
        // is deliberately linear.
        XCTAssertEqual(config.scrollFactor(forSpeed: 1.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(config.scrollFactor(forSpeed: 2.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(config.scrollFactor(forSpeed: 3.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(config.scrollFactor(forSpeed: 0), 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(config.scrollFactor(forSpeed: 6), 1.0)
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
        let effects = engine.tick(at: 0.35)
        XCTAssertEqual(messages(effects), [.click(button: .left, action: .down)])
        XCTAssertTrue(engine.isButtonHeld)
    }

    func testDoubleTapThenMovePicksUpADragSooner() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        _ = engine.touchesEnded([touch()], remaining: [], at: 0.1)
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0.2)
        let effects = engine.touchesMoved([touch(210, 400)], all: [touch(210, 400)], at: 0.22)
        XCTAssertTrue(messages(effects).contains(.click(button: .left, action: .down)))
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
        _ = engine.tick(at: 0.35)
        XCTAssertTrue(engine.isButtonHeld)

        // The call arrives, the notification lands, the system takes the touch.
        let effects = engine.touchesCancelled(at: 0.5)
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
        _ = engine.tick(at: 0.35)
        let effects = engine.touchesEnded([touch()], remaining: [], at: 0.6)
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
        guard case .scroll(let dx, let dy)? = messages(effects).first else {
            return XCTFail("expected a scroll, got \(messages(effects))")
        }
        XCTAssertEqual(dx, 0, accuracy: 0.0001)
        XCTAssertLessThan(dy, 0, "moving fingers up must scroll up")
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
        guard case .scroll(let dx, let dy)? = messages(effects).first else {
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
        guard case .scroll(let dx, let dy)? = messages(effects).first else {
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

    func testLeftEdgeSwipeSwitchesToThePreviousDesktop() {
        let engine = makeEngine()
        let start = touch(10, 400)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        let effects = engine.touchesEnded([touch(-40, 400)], remaining: [], at: 0.2)
        XCTAssertTrue(messages(effects).contains(.switchDesktop(direction: .left)))
    }

    func testRightwardEdgeSwipeSwitchesToTheNextDesktop() {
        // Unreachable in the web client: isRightEdgeGesture was declared, read
        // and reset but never set, so "next desktop" could not be triggered.
        let engine = makeEngine()
        let start = touch(390, 400)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        let effects = engine.touchesEnded([touch(340, 400)], remaining: [], at: 0.2)
        XCTAssertTrue(messages(effects).contains(.switchDesktop(direction: .left)),
                      "a leftward flick from the right edge goes to the previous desktop")

        let engine2 = makeEngine()
        let start2 = touch(10, 400)
        _ = engine2.touchesBegan([start2], all: [start2], at: 0)
        let effects2 = engine2.touchesEnded([touch(70, 400)], remaining: [], at: 0.2)
        XCTAssertTrue(messages(effects2).contains(.switchDesktop(direction: .right)),
                      "a rightward flick goes to the next desktop")
    }

    func testShortEdgeSwipeDoesNothing() {
        let engine = makeEngine()
        let start = touch(10, 400)
        _ = engine.touchesBegan([start], all: [start], at: 0)
        let effects = engine.touchesEnded([touch(25, 400)], remaining: [], at: 0.2)
        XCTAssertTrue(messages(effects).isEmpty, "under the threshold is not a swipe")
    }

    // MARK: - Pointer

    func testMovementSendsAcceleratedDeltas() {
        let engine = makeEngine()
        _ = engine.touchesBegan([touch()], all: [touch()], at: 0)
        let effects = engine.touchesMoved([touch(210, 400)], all: [touch(210, 400)], at: 0.016)
        guard case .trackpad(let dx, let dy)? = messages(effects).first else {
            return XCTFail("expected a trackpad move, got \(messages(effects))")
        }
        let config = GestureConfig()
        XCTAssertEqual(dx, 10 * config.baseSensitivity * config.accelerationFactor(forSpeed: 10),
                       accuracy: 0.0001)
        XCTAssertEqual(dy, 0, accuracy: 0.0001)
    }
}
