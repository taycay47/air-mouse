import Foundation

/// A message the Mac sends to the phone, as specified in docs/PROTOCOL.md.
///
/// Everything here except `authOk` / `authFail` is **advisory**: a client that
/// receives none of it must remain fully functional, because every one of these
/// depends on the Accessibility API, which is unavailable in some apps and can
/// be revoked at any time (ADR-0004).
public enum ServerMessage: Equatable, Sendable {
    case authOk(token: String)
    case authFail(reason: AuthFailureReason?)
    /// Whether the focused Mac element is a text field. A hint used to dim the
    /// phone's input field — it must never gate sending (ADR-0004).
    case focusState(focused: Bool)
    /// "A Mac text field just took focus." A hint, nothing more. A client must
    /// not consume a user's touch on the strength of it (ADR-0008).
    case focusKeyboard
    /// Drives the Copy / Paste pills.
    case context(hasSelection: Bool, hasClipboard: Bool)
    /// Whether the server still holds the macOS Accessibility grant. The only
    /// state message reporting something the user must act on: without the
    /// grant everything connects and nothing moves.
    case permission(accessibility: Bool)
    /// The answer to a `ping`, on the channel the ping arrived by.
    case pong(id: UInt32)
    /// An offer of a faster channel: a DTLS-over-UDP port, and the pre-shared
    /// key that authenticates it.
    ///
    /// Only ever sent over the already-authenticated, certificate-pinned
    /// connection, which is what makes handing a key over in cleartext JSON
    /// sound: the envelope is the security boundary. A client that ignores
    /// this message keeps working exactly as before — which is what every
    /// client older than this message does.
    case fastChannel(FastChannel)
    case unknown(type: String)

    public struct FastChannel: Equatable, Sendable {
        public var port: Int
        /// Base64. 32 random bytes, fresh per session.
        public var key: String
        public var identity: String
        /// A Bonjour instance name for the same listener, when it has one.
        ///
        /// Two ways to the same socket: reaching it by service lets the system
        /// choose the path, including a direct AWDL link that never touches the
        /// access point; reaching it by address is what works when it does not.
        public var service: String?

        public init(port: Int, key: String, identity: String, service: String? = nil) {
            self.port = port
            self.key = key
            self.identity = identity
            self.service = service
        }
    }
}

// MARK: - Coding

extension ServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case token
        case reason
        case focused
        case hasSelection
        case hasClipboard
        case accessibility
        case id
        case port
        case key
        case identity
        case service
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "auth_ok":
            self = .authOk(token: try container.decode(String.self, forKey: .token))

        case "auth_fail":
            let raw = try container.decodeIfPresent(String.self, forKey: .reason)
            self = .authFail(reason: raw.map(AuthFailureReason.init(wireValue:)))

        case "focus_state":
            self = .focusState(
                focused: try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false)

        case "focus_keyboard":
            self = .focusKeyboard

        case "context":
            // Unknown state is reported as false, never omitted — but decode
            // defensively anyway, since fail-closed is the documented posture
            // (ADR-0005): claiming a selection that isn't there enables a Copy
            // that silently does nothing.
            self = .context(
                hasSelection: try container.decodeIfPresent(Bool.self, forKey: .hasSelection) ?? false,
                hasClipboard: try container.decodeIfPresent(Bool.self, forKey: .hasClipboard) ?? false)

        case "permission":
            // Missing reads as granted, so a server too old to send this is not
            // reported as broken.
            self = .permission(
                accessibility: try container.decodeIfPresent(Bool.self, forKey: .accessibility) ?? true)

        case "pong":
            self = .pong(id: try container.decodeIfPresent(UInt32.self, forKey: .id) ?? 0)

        case "fast_channel":
            // A malformed offer is not an error, it is simply no offer: the
            // reliable channel is already carrying everything.
            guard let port = try container.decodeIfPresent(Int.self, forKey: .port),
                  let key = try container.decodeIfPresent(String.self, forKey: .key),
                  let identity = try container.decodeIfPresent(String.self, forKey: .identity)
            else {
                self = .unknown(type: type)
                return
            }
            self = .fastChannel(FastChannel(
                port: port, key: key, identity: identity,
                service: try container.decodeIfPresent(String.self, forKey: .service)))

        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .authOk(let token):
            try container.encode("auth_ok", forKey: .type)
            try container.encode(token, forKey: .token)

        case .authFail(let reason):
            try container.encode("auth_fail", forKey: .type)
            try container.encodeIfPresent(reason?.wireValue, forKey: .reason)

        case .focusState(let focused):
            try container.encode("focus_state", forKey: .type)
            try container.encode(focused, forKey: .focused)

        case .focusKeyboard:
            try container.encode("focus_keyboard", forKey: .type)

        case .context(let hasSelection, let hasClipboard):
            try container.encode("context", forKey: .type)
            try container.encode(hasSelection, forKey: .hasSelection)
            try container.encode(hasClipboard, forKey: .hasClipboard)

        case .permission(let accessibility):
            try container.encode("permission", forKey: .type)
            try container.encode(accessibility, forKey: .accessibility)

        case .pong(let id):
            try container.encode("pong", forKey: .type)
            try container.encode(id, forKey: .id)

        case .fastChannel(let offer):
            try container.encode("fast_channel", forKey: .type)
            try container.encode(offer.port, forKey: .port)
            try container.encode(offer.key, forKey: .key)
            try container.encode(offer.identity, forKey: .identity)
            try container.encodeIfPresent(offer.service, forKey: .service)

        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}
