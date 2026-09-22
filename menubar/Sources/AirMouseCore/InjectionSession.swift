import Foundation
import CoreGraphics

// Describes an Accessibility/clipboard check that should run after a message
// was handled, ported from mouse_controller.py's calls to _check_text_focus.
// This is purely advisory (docs/adr/0004, docs/adr/0005): the caller decides
// whether/how to act on it, and InjectionSession itself never waits on it.
public enum AccessibilityTrigger {
    case none
    case checkFocus(delaySeconds: Double, clipboardChanged: Bool, announceFocus: Bool)
}

// Per-connection injection state and message dispatch. Ported from mouse_controller.py's
// handle_ws_client dispatch loop. Per-connection fields here (cursor tracking, gyro EMA
// smoothing) mirror Python's locals inside that function; drag flags/scroll accumulator/
// bounds cache are process-global (see DeviceActions.swift) matching Python's module-level
// globals.
public final class InjectionSession {
    private var cursorX = 0.0
    private var cursorY = 0.0
    private var lastPacketTime = 0.0
    private var smoothedDx = 0.0
    private var smoothedDy = 0.0
    private let gyroSmoothingFactor = 0.30

    public init() {
        (cursorX, cursorY) = mousePosition()
    }

    @discardableResult
    public func handle(_ packet: [String: Any]) -> AccessibilityTrigger {
        guard let type = packet["type"] as? String else { return .none }

        // Periodically resync cursor tracking with the real OS position, to absorb
        // physical-mouse movement gaps between packets — ported from handle_ws_client.
        let t = monotonicNow()
        if t - lastPacketTime > 0.10 {
            (cursorX, cursorY) = mousePosition()
        }
        lastPacketTime = t

        var trigger: AccessibilityTrigger = .none

        switch type {
        case "trackpad":
            let dx = numberField(packet, "dx")
            let dy = numberField(packet, "dy")

            cursorX += dx
            cursorY += dy

            let b = virtualDesktopBounds()
            cursorX = max(b.xMin, min(b.xMax - 1.0, cursorX))
            cursorY = max(b.yMin, min(b.yMax - 1.0, cursorY))

            let eventType: CGEventType = isLeftDown ? .leftMouseDragged : .mouseMoved
            postMouseEvent(eventType, cursorX, cursorY)

        case "motion":
            let rx = numberField(packet, "rx")
            let ry = numberField(packet, "ry")
            let rz = numberField(packet, "rz")
            let isLandscape = boolField(packet, "is_landscape")
            let signX = numberField(packet, "sign_x", default: 1.0)
            let signY = numberField(packet, "sign_y", default: 1.0)

            let yawRate: Double
            let pitchRate: Double
            if isLandscape {
                yawRate = rz * signX
                pitchRate = -rx * signX
            } else {
                yawRate = -rx
                pitchRate = ry * signY
            }

            var rawDx = yawRate
            var rawDy = -pitchRate

            let speed = (rawDx * rawDx + rawDy * rawDy).squareRoot()
            if speed > 0 {
                let factor = gyroFactor(speed)
                rawDx *= factor
                rawDy *= factor
            }

            smoothedDx = gyroSmoothingFactor * rawDx + (1.0 - gyroSmoothingFactor) * smoothedDx
            smoothedDy = gyroSmoothingFactor * rawDy + (1.0 - gyroSmoothingFactor) * smoothedDy

            if abs(smoothedDx) > 0.05 || abs(smoothedDy) > 0.05 {
                cursorX += smoothedDx
                cursorY += smoothedDy

                let b = virtualDesktopBounds()
                cursorX = max(b.xMin, min(b.xMax - 1.0, cursorX))
                cursorY = max(b.yMin, min(b.yMax - 1.0, cursorY))

                let eventType: CGEventType = isLeftDown ? .leftMouseDragged : .mouseMoved
                postMouseEvent(eventType, cursorX, cursorY)
            }

        case "scroll":
            let dy = numberField(packet, "dy")
            let dx = numberField(packet, "dx")
            // Modifiers turn a scroll into a zoom in apps that map ⌘-scroll to
            // one. Absent on an ordinary scroll, which is every message any
            // older client has ever sent.
            let scrollModifiers = (packet["modifiers"] as? [String]) ?? []
            scrollMouse(dy: dy, dx: dx, modifiers: scrollModifiers)

        case "click":
            let button = stringField(packet, "button", default: "left")
            let action = stringField(packet, "action", default: "tap")
            let (cx, cy) = mousePosition()
            cursorX = cx
            cursorY = cy

            if button == "left" {
                switch action {
                case "down":
                    isLeftDown = true
                    postMouseEvent(.leftMouseDown, cx, cy, button: .left)
                case "up":
                    // Releasing a drag is how text gets selected.
                    let wasDragging = isLeftDown
                    isLeftDown = false
                    postMouseEvent(.leftMouseUp, cx, cy, button: .left)
                    if wasDragging {
                        trigger = .checkFocus(delaySeconds: 0.20, clipboardChanged: false, announceFocus: false)
                    }
                case "tap":
                    postMouseEvent(.leftMouseDown, cx, cy, button: .left)
                    Thread.sleep(forTimeInterval: 0.01)
                    postMouseEvent(.leftMouseUp, cx, cy, button: .left)
                    // A tap is the only action that sets announceFocus, so it is the
                    // only one that can emit focus_keyboard. That message is a hint —
                    // "a Mac text field just took focus" — and nothing more: the client
                    // opens the keyboard on an explicit double-tap, inside a real touch
                    // event, and works fine if the hint never arrives (ADR-0004,
                    // ADR-0008). It must never arm anything client-side.
                    trigger = .checkFocus(delaySeconds: 0.20, clipboardChanged: false, announceFocus: true)
                case "double_tap":
                    postMouseEvent(.leftMouseDown, cx, cy, button: .left, clickCount: 2)
                    Thread.sleep(forTimeInterval: 0.01)
                    postMouseEvent(.leftMouseUp, cx, cy, button: .left, clickCount: 2)
                    // Double-click selects a word. Never arms the keyboard (ADR-0004).
                    trigger = .checkFocus(delaySeconds: 0.20, clipboardChanged: false, announceFocus: false)
                default:
                    break
                }
            } else if button == "right" {
                // Parity with mouse_controller.py: right button has no double_tap case.
                switch action {
                case "down":
                    isRightDown = true
                    postMouseEvent(.rightMouseDown, cx, cy, button: .right)
                case "up":
                    isRightDown = false
                    postMouseEvent(.rightMouseUp, cx, cy, button: .right)
                case "tap":
                    postMouseEvent(.rightMouseDown, cx, cy, button: .right)
                    Thread.sleep(forTimeInterval: 0.01)
                    postMouseEvent(.rightMouseUp, cx, cy, button: .right)
                default:
                    break
                }
            }

        case "key":
            let code = stringField(packet, "code")
            let modifiers = (packet["modifiers"] as? [String]) ?? []
            if let keycode = KEY_CODES[code] {
                pressKey(CGKeyCode(keycode), modifiers: modifiers)
                // Cmd+C/X/V/A change the selection or the clipboard.
                if ["c", "v", "x", "a"].contains(code) && modifiers.contains("cmd") {
                    trigger = .checkFocus(
                        delaySeconds: 0.12,
                        clipboardChanged: code == "c" || code == "x",
                        announceFocus: false
                    )
                }
            } else {
                // Function-row actions: media transport, volume, Mission
                // Control. Each needs its own route into macOS, none of them a
                // virtual keycode (SystemKeys.swift). Still ignored silently if
                // unrecognised, per protocol invariant 2.
                _ = pressSystemKey(code)
            }

        case "keyboard":
            let text = stringField(packet, "text")
            if !text.isEmpty {
                typeString(text)
            }

        case "switch_desktop":
            let direction = stringField(packet, "direction", default: "right")
            switchDesktop(direction: direction)

        case "calibrate":
            smoothedDx = 0.0
            smoothedDy = 0.0

        default:
            break // unknown type — ignored (protocol invariant 2)
        }

        return trigger
    }
}
