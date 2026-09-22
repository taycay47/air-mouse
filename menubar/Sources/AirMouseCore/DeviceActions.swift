import Foundation
import CoreGraphics

// Device-action primitives, ported from mouse_controller.py's "Device Actions Wrappers".
//
// Drag flags, the scroll accumulator, and the virtual-desktop-bounds cache are
// process-global, matching Python's module-level globals (shared across every
// connection, not per-session) — see docs/adr/0002-port-input-injection-from-python-to-swift.md's
// warning that mutable state across packets is where subtle drift hides.

struct Bounds {
    var xMin: Double
    var yMin: Double
    var xMax: Double
    var yMax: Double
}

var boundsCache: Bounds?
var boundsCacheTime: Double = 0

func monotonicNow() -> Double {
    ProcessInfo.processInfo.systemUptime
}

func virtualDesktopBounds() -> Bounds {
    let t = monotonicNow()
    if let cached = boundsCache, t - boundsCacheTime < 5.0 {
        return cached
    }

    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)

    let result: Bounds
    if count == 0 {
        let main = CGMainDisplayID()
        let b = CGDisplayBounds(main)
        result = Bounds(xMin: 0, yMin: 0, xMax: b.size.width, yMax: b.size.height)
    } else {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        CGGetActiveDisplayList(count, &displayIDs, &actual)

        var xMin = Double.infinity, yMin = Double.infinity
        var xMax = -Double.infinity, yMax = -Double.infinity
        for i in 0..<Int(actual) {
            let b = CGDisplayBounds(displayIDs[i])
            xMin = min(xMin, b.origin.x)
            yMin = min(yMin, b.origin.y)
            xMax = max(xMax, b.origin.x + b.size.width)
            yMax = max(yMax, b.origin.y + b.size.height)
        }
        result = Bounds(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    boundsCache = result
    boundsCacheTime = t
    return result
}

func mousePosition() -> (Double, Double) {
    guard let event = CGEvent(source: nil) else { return (0, 0) }
    let loc = event.location
    return (loc.x, loc.y)
}

func postMouseEvent(_ type: CGEventType, _ x: Double, _ y: Double, button: CGMouseButton = .left, clickCount: Int64 = 1) {
    let b = virtualDesktopBounds()
    let cx = max(b.xMin, min(b.xMax - 1.0, x))
    let cy = max(b.yMin, min(b.yMax - 1.0, y))

    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: button) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clickCount)
    event.post(tap: .cghidEventTap)
}

var scrollAccumX = 0.0
var scrollAccumY = 0.0

/// How many pixels one unit of the client's scroll delta is worth.
///
/// The client's curves were tuned against *line* units, so its numbers mean
/// "lines" and have to be converted to the pixels this now sends. macOS uses
/// roughly this ratio internally when it converts a wheel notch to a distance.
///
/// This is a unit conversion, not a curve: the shape of the motion is still
/// entirely the client's (PROTOCOL.md invariant 1). Overridable so the feel can
/// be tuned by restarting the server rather than rebuilding the phone app:
///
///     AIRMOUSE_SCROLL_SCALE=6 AirMouseServer 8443
let scrollPixelsPerUnit: Double = {
    if let raw = ProcessInfo.processInfo.environment["AIRMOUSE_SCROLL_SCALE"],
       let value = Double(raw), value > 0 {
        return value
    }
    return 10.0
}()

// Scrolling as a trackpad does it, rather than as a mouse wheel.
//
// This used to post `.line` units with no phase and no continuity flag, which
// is a *wheel* event as far as macOS is concerned — and apps deliberately
// render wheel input as discrete notched steps, often animating each one. That
// is most of why scrolling felt jagged: not coarse numbers, but the wrong class
// of event entirely.
//
// Two changes. Pixel units, so the accumulator quantises to whole pixels rather
// than whole lines — a stream of sub-line deltas used to truncate to 0, 0, 1,
// 0, 1 and then get multiplied back up by ten. And the continuous flag, which
// is what tells macOS this came from a device that scrolls smoothly.
//
// Still absent, deliberately, because it needs the client to say so: the scroll
// *phase* (began/changed/ended). Without it there is no rubber-banding at a
// document's edges and macOS cannot run momentum itself.
func scrollMouse(dy: Double, dx: Double, modifiers: [String] = []) {
    if dy == 0 && dx == 0 { return }

    scrollAccumX += dx * scrollPixelsPerUnit
    scrollAccumY += dy * scrollPixelsPerUnit

    let intDx = Int32(scrollAccumX.rounded(.towardZero))
    let intDy = Int32(scrollAccumY.rounded(.towardZero))

    if intDx != 0 || intDy != 0 {
        // Only the whole pixels are spent; the remainder stays for next time,
        // which is what stops a slow drag from rounding away to nothing.
        scrollAccumX -= Double(intDx)
        scrollAccumY -= Double(intDy)

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: intDy, wheel2: intDx, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // What an app reads for pixel-accurate scrolling. Set explicitly rather
        // than relying on the pixel units to populate it.
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(intDy))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(intDx))
        // ⌘-scroll is zoom in Figma, Canva, browsers and most creative tools —
        // the same path their own pinch-to-zoom takes. A real magnify event
        // (NSEventTypeMagnify) cannot be posted with public API at all, so this
        // is how a pinch on the phone reaches them.
        var flags: CGEventFlags = []
        for name in modifiers {
            if let flag = MODIFIER_FLAGS[name] { flags.insert(flag) }
        }
        // Assigned even when empty. An event built from the HID system state
        // inherits whatever modifiers macOS believes are held — and after a
        // ⌘-scroll it believes ⌘ is held (see releaseModifiers). A plain pan
        // that merely *didn't set* flags went out as ⌘-scroll, which is a zoom.
        event.flags = flags
        event.post(tap: .cghidEventTap)
        if !flags.isEmpty { releaseModifiers(source: source) }
    }
}

func pressKey(_ keycode: CGKeyCode, modifiers: [String]) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) else { return }

    var flags: CGEventFlags = []
    for name in modifiers {
        if let f = MODIFIER_FLAGS[name] { flags.insert(f) }
    }
    // Explicit even when empty, so a plain key cannot inherit a modifier some
    // earlier event left behind.
    down.flags = flags
    up.flags = flags

    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    // Without this, ⌘C from the copy pill left ⌘ "held" too — the bug predates
    // pinch-to-zoom, it just had nothing to make it visible.
    if !flags.isEmpty { releaseModifiers(source: source) }
}

/// Tells macOS the modifiers are no longer held.
///
/// Posting an event that carries a modifier — a ⌘-scroll for a pinch, ⌘C from
/// the copy pill — updates the system's own record of which modifiers are down,
/// and nothing ever took it back. Every event built from the HID system state
/// afterwards inherited the phantom ⌘: pans became zooms, clicks became
/// ⌘-clicks. Verified directly: CGEventSource.flagsState reports ⌘ down after a
/// single posted ⌘-scroll, and clear again after this.
///
/// A flags-changed event with no modifiers is what a real keyboard sends on
/// releasing ⌘, so every app already understands it.
func releaseModifiers(source: CGEventSource) {
    guard let release = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else { return }
    release.type = .flagsChanged
    release.flags = []
    release.post(tap: .cghidEventTap)
}

func typeString(_ text: String) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    let utf16 = Array(text.utf16)
    for isDown in [true, false] {
        // virtual key 0 is 'a', a placeholder — overridden by keyboardSetUnicodeString below.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
        // Text is text. Inheriting a phantom ⌘ here would turn typing "q" into
        // ⌘Q, which quits whatever is in front.
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        event.post(tap: .cghidEventTap)
    }
}

func switchDesktop(direction: String) {
    // Per docs/PROTOCOL.md's port note: Mission Control silently drops synthetic
    // modifier flags posted via CGEventPost from a non-HID source, so this must go
    // through osascript/System Events, not CGEvent. Requires the Automation permission.
    let keycode = direction == "right" ? 124 : 123
    systemEventsKey(keycode, using: "control down", label: "Desktop")
}

// Ported from handle_ws_client's inline gyro_factor: dampen slow jitter, neutral
// mid-range, gentle expo acceleration for fast sweeps.
func gyroFactor(_ speed: Double) -> Double {
    if speed < 1.5 {
        return 0.3 + (speed / 1.5) * 0.7
    } else if speed > 5.0 {
        return 1.0 + pow(speed - 5.0, 1.05) * 0.09
    }
    return 1.0
}

// MARK: - Shared drag-flag state (process-global, matches Python's is_left_down/is_right_down)

var isLeftDown = false
var isRightDown = false

// Protocol invariant 4 / ADR-0006: a held button must always be released — on
// process exit (signal handlers) or on any connection ending (Connection.swift),
// mirroring mouse_controller.py's atexit-registered _release_all_buttons and
// handle_ws_client's `finally` cleanup, both of which act on the same shared flags
// regardless of which connection set them.
public func releaseHeldButtons() {
    if isLeftDown {
        let (cx, cy) = mousePosition()
        postMouseEvent(.leftMouseUp, cx, cy, button: .left)
        isLeftDown = false
    }
    if isRightDown {
        let (cx, cy) = mousePosition()
        postMouseEvent(.rightMouseUp, cx, cy, button: .right)
        isRightDown = false
    }
}
