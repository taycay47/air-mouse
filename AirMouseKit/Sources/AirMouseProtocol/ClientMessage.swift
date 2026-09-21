import Foundation

/// A message the phone sends to the Mac, as specified in docs/PROTOCOL.md.
///
/// `unknown` is a first-class case rather than a decoding error. The spec
/// requires unrecognised `type` values to be ignored, not rejected — that is
/// what lets one side ship a message before the other understands it — so the
/// decoder never throws on an unfamiliar message, only on malformed JSON.
public enum ClientMessage: Equatable, Sendable {
    case auth(Auth)
    /// Deltas in points, already scaled and accelerated by the client. The
    /// server must not apply its own curve (PROTOCOL.md invariant 1).
    case trackpad(dx: Double, dy: Double)
    case motion(Motion)
    case scroll(dx: Double, dy: Double)
    case click(button: MouseButton, action: ClickAction)
    case key(code: String, modifiers: [KeyModifier])
    /// Literal text, typed verbatim. Deletion is never expressed here — the
    /// client sends an explicit `key` with code `backspace`.
    case keyboard(text: String)
    case switchDesktop(direction: DesktopDirection)
    case calibrate
    /// A recognised envelope carrying a `type` this build does not know, or a
    /// known type whose payload could not be understood. Ignore it.
    case unknown(type: String)

    /// Exactly one of `token` or `pin`, per the spec.
    public enum Auth: Equatable, Sendable {
        case token(String)
        case pin(String)
    }

    public struct Motion: Equatable, Sendable {
        /// Angular deltas, already scaled by the client's sensitivity setting.
        public var rx: Double
        public var ry: Double
        public var rz: Double
        /// Lets the client map device axes to screen axes without the server
        /// knowing anything about device orientation.
        public var isLandscape: Bool
        public var signX: Double
        public var signY: Double

        public init(rx: Double, ry: Double, rz: Double,
                    isLandscape: Bool, signX: Double, signY: Double) {
            self.rx = rx
            self.ry = ry
            self.rz = rz
            self.isLandscape = isLandscape
            self.signX = signX
            self.signY = signY
        }
    }
}

// MARK: - Coding

extension ClientMessage: Codable {
    // The wire format mixes conventions — `is_landscape` and `sign_x` are
    // snake_case while the server's own `hasSelection` is camelCase — so the
    // keys are spelled out rather than derived by a global strategy, which
    // would silently rename one group or the other.
    private enum CodingKeys: String, CodingKey {
        case type
        case token, pin
        case dx, dy
        case rx, ry, rz
        case isLandscape = "is_landscape"
        case signX = "sign_x"
        case signY = "sign_y"
        case button, action
        case code, modifiers
        case text
        case direction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "auth":
            // Token wins when both are present: it is the stronger credential,
            // and the spec allows exactly one, so this is already malformed.
            if let token = try container.decodeIfPresent(String.self, forKey: .token) {
                self = .auth(.token(token))
            } else if let pin = try container.decodeIfPresent(String.self, forKey: .pin) {
                self = .auth(.pin(pin))
            } else {
                self = .unknown(type: type)
            }

        case "trackpad":
            self = .trackpad(
                dx: try container.decodeIfPresent(Double.self, forKey: .dx) ?? 0,
                dy: try container.decodeIfPresent(Double.self, forKey: .dy) ?? 0)

        case "scroll":
            self = .scroll(
                dx: try container.decodeIfPresent(Double.self, forKey: .dx) ?? 0,
                dy: try container.decodeIfPresent(Double.self, forKey: .dy) ?? 0)

        case "motion":
            self = .motion(Motion(
                rx: try container.decodeIfPresent(Double.self, forKey: .rx) ?? 0,
                ry: try container.decodeIfPresent(Double.self, forKey: .ry) ?? 0,
                rz: try container.decodeIfPresent(Double.self, forKey: .rz) ?? 0,
                isLandscape: try container.decodeIfPresent(Bool.self, forKey: .isLandscape) ?? false,
                signX: try container.decodeIfPresent(Double.self, forKey: .signX) ?? 1,
                signY: try container.decodeIfPresent(Double.self, forKey: .signY) ?? 1))

        case "click":
            guard let button = MouseButton(rawValue: try container.decode(String.self, forKey: .button)),
                  let action = ClickAction(rawValue: try container.decode(String.self, forKey: .action))
            else {
                self = .unknown(type: type)
                return
            }
            self = .click(button: button, action: action)

        case "key":
            let code = try container.decode(String.self, forKey: .code)
            let raw = try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
            let modifiers = raw.compactMap(KeyModifier.init(rawValue:))
            // An unrecognised modifier invalidates the whole keystroke rather
            // than being dropped. Dropping it would turn ⌘C into a bare C —
            // silently doing something *different* from what was asked, which is
            // worse than doing nothing.
            guard modifiers.count == raw.count else {
                self = .unknown(type: type)
                return
            }
            self = .key(code: code, modifiers: modifiers)

        case "keyboard":
            self = .keyboard(text: try container.decode(String.self, forKey: .text))

        case "switch_desktop":
            guard let direction = DesktopDirection(
                rawValue: try container.decode(String.self, forKey: .direction))
            else {
                self = .unknown(type: type)
                return
            }
            self = .switchDesktop(direction: direction)

        case "calibrate":
            self = .calibrate

        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auth(let auth):
            try container.encode("auth", forKey: .type)
            switch auth {
            case .token(let token): try container.encode(token, forKey: .token)
            case .pin(let pin): try container.encode(pin, forKey: .pin)
            }

        case .trackpad(let dx, let dy):
            try container.encode("trackpad", forKey: .type)
            try container.encode(dx, forKey: .dx)
            try container.encode(dy, forKey: .dy)

        case .scroll(let dx, let dy):
            try container.encode("scroll", forKey: .type)
            try container.encode(dx, forKey: .dx)
            try container.encode(dy, forKey: .dy)

        case .motion(let m):
            try container.encode("motion", forKey: .type)
            try container.encode(m.rx, forKey: .rx)
            try container.encode(m.ry, forKey: .ry)
            try container.encode(m.rz, forKey: .rz)
            try container.encode(m.isLandscape, forKey: .isLandscape)
            try container.encode(m.signX, forKey: .signX)
            try container.encode(m.signY, forKey: .signY)

        case .click(let button, let action):
            try container.encode("click", forKey: .type)
            try container.encode(button.rawValue, forKey: .button)
            try container.encode(action.rawValue, forKey: .action)

        case .key(let code, let modifiers):
            try container.encode("key", forKey: .type)
            try container.encode(code, forKey: .code)
            if !modifiers.isEmpty {
                try container.encode(modifiers.map(\.rawValue), forKey: .modifiers)
            }

        case .keyboard(let text):
            try container.encode("keyboard", forKey: .type)
            try container.encode(text, forKey: .text)

        case .switchDesktop(let direction):
            try container.encode("switch_desktop", forKey: .type)
            try container.encode(direction.rawValue, forKey: .direction)

        case .calibrate:
            try container.encode("calibrate", forKey: .type)

        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}
