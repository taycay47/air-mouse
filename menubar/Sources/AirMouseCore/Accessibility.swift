import Foundation
import ApplicationServices

// Ported from mouse_controller.py's _copy_ax_string / _check_text_focus /
// _clipboard_has_text. Per docs/adr/0004 (focus state must never gate input)
// and docs/adr/0005 (event-driven, fail-closed), callers must treat every
// result here as advisory only, and must never let a check delay or block
// sending real input.

/// Whether this process currently holds the Accessibility grant.
///
/// Exposed because losing it is otherwise a completely silent failure: the
/// server still accepts connections, the phone still pairs, every message is
/// still accepted — and nothing moves. The client is told so it can say so.
public func hasAccessibilityPermission() -> Bool {
    AXIsProcessTrusted()
}

public struct FocusInfo {
    public let isTextField: Bool
    public let hasSelection: Bool
}

private let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField", "AXComboBox"]

// AX/clipboard reads are serialized onto a dedicated background queue, never the
// caller's thread and never the main thread.
//
// Not the caller's: it's the network event loop, and per docs/adr/0005 an AX read
// (hundreds of ms in Electron apps) must never stall cursor movement.
//
// Not main: inside the GUI app the main queue is busy with SwiftUI work, which
// added 60–130ms of queueing delay on top of the intended 200ms — enough to matter
// for focus_keyboard, which the phone consumes on its next touch — and it would
// also block the UI for the duration of the read.
//
// Serial (not concurrent) so overlapping checks can't race on clipboardCache.
private let accessibilityQueue = DispatchQueue(label: "com.airmouse.accessibility")

public func performFocusAndClipboardCheck(clipboardChanged: Bool, completion: @escaping (FocusInfo, Bool) -> Void) {
    accessibilityQueue.async {
        let focus = checkTextFocus()
        let hasClipboard = clipboardHasText(force: clipboardChanged)
        completion(focus, hasClipboard)
    }
}

private func checkTextFocus() -> FocusInfo {
    guard AXIsProcessTrusted() else {
        return FocusInfo(isTextField: false, hasSelection: false)
    }

    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
    guard err == .success, let focusedRef else {
        return FocusInfo(isTextField: false, hasSelection: false)
    }
    let focusedElement = focusedRef as! AXUIElement // swiftlint:disable:this force_cast

    let role = copyAXString(focusedElement, attribute: kAXRoleAttribute as CFString)
    let selected = copyAXString(focusedElement, attribute: kAXSelectedTextAttribute as CFString)

    let isText = role.map { textRoles.contains($0) } ?? false
    // Absent selection is treated as "no selection" (fail-closed) — not every
    // app exposes AXSelectedText.
    let hasSelection = !(selected?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    return FocusInfo(isTextField: isText, hasSelection: hasSelection)
}

private func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard err == .success, let value else { return nil }
    // AXSelectedText in particular can come back as any CF type; guard the
    // type before treating it as a string.
    guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
    return (value as! CFString) as String // swiftlint:disable:this force_cast
}

private var clipboardCache: (checkedAt: Double, hasText: Bool) = (0, false)
private let clipboardTTL: Double = 3.0

// Cached: this runs after every tap, and spawning pbpaste that often would add
// subprocess latency to the click path for no benefit.
private func clipboardHasText(force: Bool) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    if !force, now - clipboardCache.checkedAt < clipboardTTL {
        return clipboardCache.hasText
    }
    let hasText = pbpasteHasText()
    clipboardCache = (now, hasText)
    return hasText
}

private func pbpasteHasText() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } catch {
        return false
    }
}
