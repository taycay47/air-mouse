import AppKit
import CoreGraphics
import Foundation

// Keys that are not keys.
//
// The function row sends nothing a virtual keycode can express. Play/pause and
// the volume keys are NX_SYSDEFINED events — a separate event type the media
// subsystem listens for — and Mission Control refuses synthetic modifiers
// entirely, the same way desktop switching does. So each of these reaches macOS
// by its own route, and `key` stays one message on the wire.
//
// Deliberately absent: brightness and dictation. Brightness moved behind a
// private framework years ago and no longer responds to NX_KEYTYPE_BRIGHTNESS;
// dictation is bound to a double-press of a modifier key, which is not a
// keystroke at all. Both would ship as buttons that quietly do nothing, which
// is the one thing a remote control must never do.

/// NX_KEYTYPE constants from IOKit's ev_keymap.h. Not imported, because the
/// header is not exposed to Swift.
let MEDIA_KEYS: [String: Int32] = [
    "volumeup": 0,     // NX_KEYTYPE_SOUND_UP
    "volumedown": 1,   // NX_KEYTYPE_SOUND_DOWN
    "mute": 7,         // NX_KEYTYPE_MUTE
    "playpause": 16,   // NX_KEYTYPE_PLAY
    "nexttrack": 17,   // NX_KEYTYPE_NEXT
    "previoustrack": 18, // NX_KEYTYPE_PREVIOUS
]

/// Posts a media key as the system-defined event the media subsystem expects.
///
/// The encoding is fixed: `data1` packs the key type and the up/down phase, the
/// modifier flags carry the same phase again, and `data2` is -1. It is strange,
/// but it is what the HID layer emits and therefore what everything downstream
/// recognises.
func pressMediaKey(_ keyType: Int32) {
    for isDown in [true, false] {
        let phase: Int32 = isDown ? 0xA : 0xB
        let data1 = Int((keyType << 16) | (phase << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(phase) << 8),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        ) else { continue }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}

/// Sends a keystroke through System Events rather than CGEvent.
///
/// Mission Control and desktop switching both ignore synthetic modifier flags
/// posted from a non-HID source (see docs/PROTOCOL.md's port note), so they have
/// to be asked for by name. Requires the Automation permission.
func systemEventsKey(_ keycode: Int, using modifier: String, label: String) {
    let script = "tell application \"System Events\" to key code \(keycode) using \(modifier)"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let errPipe = Pipe()
    process.standardError = errPipe

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errText = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            logError("[\(label)] osascript failed (code \(process.terminationStatus)): \(errText)")
        }
    } catch {
        logError("[\(label)] failed to launch osascript: \(error)")
    }
}

/// Codes handled outside the `KEY_CODES` table. Returns false if this build
/// does not know the code, so the caller can ignore it per protocol invariant 2.
func pressSystemKey(_ code: String) -> Bool {
    if let media = MEDIA_KEYS[code] {
        pressMediaKey(media)
        return true
    }
    if code == "missioncontrol" {
        // Control+Up, the shortcut Mission Control actually listens for. There
        // is no virtual keycode for the F3 glyph on the function row.
        systemEventsKey(126, using: "control down", label: "MissionControl")
        return true
    }
    return false
}
