import Foundation

// The small closed vocabularies used inside messages. Each is RawRepresentable
// over its wire spelling, and each decodes *failably* — an unrecognised value
// makes the enclosing message decode as `.unknown` rather than throwing, which
// is what docs/PROTOCOL.md requires of unknown input in both directions.

public enum MouseButton: String, Codable, Sendable, CaseIterable {
    case left
    case right
}

public enum ClickAction: String, Codable, Sendable, CaseIterable {
    /// Press and release.
    case tap
    /// Press and hold — begins a drag.
    case down
    /// Release a held button.
    case up
    /// Two-click sequence (`click_count = 2`).
    case doubleTap = "double_tap"
}

public enum KeyModifier: String, Codable, Sendable, CaseIterable {
    case cmd
    case shift
    case alt
    case ctrl
}

public enum DesktopDirection: String, Codable, Sendable, CaseIterable {
    case left
    case right
}

/// Why an `auth` attempt was refused. Open-ended on the wire: the spec lists
/// only `rate_limited` today, and an unrecognised reason must not stop a client
/// from understanding that the attempt failed.
public enum AuthFailureReason: Equatable, Sendable {
    case rateLimited
    case other(String)

    public init(wireValue: String) {
        self = wireValue == "rate_limited" ? .rateLimited : .other(wireValue)
    }

    public var wireValue: String {
        switch self {
        case .rateLimited: return "rate_limited"
        case .other(let raw): return raw
        }
    }
}
