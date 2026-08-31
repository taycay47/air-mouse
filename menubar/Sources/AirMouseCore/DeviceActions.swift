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

func scrollMouse(dy: Double, dx: Double) {
    if dy == 0 && dx == 0 { return }

    scrollAccumX += dx
    scrollAccumY += dy

    let intDx = Int32(scrollAccumX.rounded(.towardZero))
    let intDy = Int32(scrollAccumY.rounded(.towardZero))

    if intDx != 0 || intDy != 0 {
        scrollAccumX -= Double(intDx)
        scrollAccumY -= Double(intDy)

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: intDy, wheel2: intDx, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
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
    if !flags.isEmpty {
        down.flags = flags
        up.flags = flags
    }

    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func typeString(_ text: String) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    let utf16 = Array(text.utf16)
    for isDown in [true, false] {
        // virtual key 0 is 'a', a placeholder — overridden by keyboardSetUnicodeString below.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        event.post(tap: .cghidEventTap)
    }
}

func switchDesktop(direction: String) {
    // Per docs/PROTOCOL.md's port note: Mission Control silently drops synthetic
    // modifier flags posted via CGEventPost from a non-HID source, so this must go
    // through osascript/System Events, not CGEvent. Requires the Automation permission.
    let keycode = direction == "right" ? 124 : 123
    let script = "tell application \"System Events\" to key code \(keycode) using control down"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let errPipe = Pipe()
    process.standardError = errPipe

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            logError("[Desktop] osascript failed (code \(process.terminationStatus)): \(errText)")
        }
    } catch {
        logError("[Desktop] failed to launch osascript: \(error)")
    }
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
