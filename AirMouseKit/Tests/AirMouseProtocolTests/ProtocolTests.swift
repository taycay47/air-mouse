import XCTest
@testable import AirMouseProtocol

/// The wire format is the contract between two codebases that ship separately,
/// so these tests assert against the literal JSON in docs/PROTOCOL.md rather
/// than against the types' own round-trips. A round-trip-only test passes
/// happily while both sides agree on the wrong spelling.
final class ProtocolTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func decodeClient(_ json: String) throws -> ClientMessage {
        try decoder.decode(ClientMessage.self, from: Data(json.utf8))
    }

    private func decodeServer(_ json: String) throws -> ServerMessage {
        try decoder.decode(ServerMessage.self, from: Data(json.utf8))
    }

    /// Encodes and reads back as a dictionary, so assertions can name wire keys.
    private func wire(_ message: some Encodable) throws -> [String: Any] {
        let data = try encoder.encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Client → server

    func testDecodesTrackpad() throws {
        let message = try decodeClient(#"{"type":"trackpad","dx":12.4,"dy":-3.1}"#)
        XCTAssertEqual(message, .trackpad(dx: 12.4, dy: -3.1))
    }

    func testDecodesMotionWithSnakeCaseKeys() throws {
        let message = try decodeClient(#"""
        {"type":"motion","rx":0.8,"ry":-0.2,"rz":0.1,
         "is_landscape":false,"sign_x":1.0,"sign_y":-1.0}
        """#)
        XCTAssertEqual(message, .motion(.init(
            rx: 0.8, ry: -0.2, rz: 0.1, isLandscape: false, signX: 1.0, signY: -1.0)))
    }

    func testEncodesMotionWithSnakeCaseKeys() throws {
        let json = try wire(ClientMessage.motion(.init(
            rx: 1, ry: 2, rz: 3, isLandscape: true, signX: 1, signY: -1)))
        // The spelling is the whole point: a camelCase key here is a message the
        // Python and Swift servers both silently ignore.
        XCTAssertEqual(json["is_landscape"] as? Bool, true)
        XCTAssertEqual(json["sign_x"] as? Double, 1)
        XCTAssertEqual(json["sign_y"] as? Double, -1)
        XCTAssertNil(json["isLandscape"])
    }

    func testDecodesDoubleTapUnderscoreSpelling() throws {
        let message = try decodeClient(#"{"type":"click","button":"left","action":"double_tap"}"#)
        XCTAssertEqual(message, .click(button: .left, action: .doubleTap))
    }

    func testEncodesSwitchDesktopWithUnderscoreType() throws {
        let json = try wire(ClientMessage.switchDesktop(direction: .left))
        XCTAssertEqual(json["type"] as? String, "switch_desktop")
        XCTAssertEqual(json["direction"] as? String, "left")
    }

    func testDecodesKeyWithModifiers() throws {
        let message = try decodeClient(#"{"type":"key","code":"c","modifiers":["cmd"]}"#)
        XCTAssertEqual(message, .key(code: "c", modifiers: [.cmd]))
    }

    func testDecodesKeyWithoutModifiers() throws {
        let message = try decodeClient(#"{"type":"key","code":"backspace"}"#)
        XCTAssertEqual(message, .key(code: "backspace", modifiers: []))
    }

    func testAuthPrefersTokenOverPin() throws {
        let message = try decodeClient(#"{"type":"auth","token":"abc","pin":"123456"}"#)
        XCTAssertEqual(message, .auth(.token("abc")))
    }

    func testAuthWithNeitherCredentialIsUnknown() throws {
        XCTAssertEqual(try decodeClient(#"{"type":"auth"}"#), .unknown(type: "auth"))
    }

    // MARK: - Unknown input is ignored, not rejected

    func testUnknownTypeDecodesRatherThanThrowing() throws {
        // PROTOCOL.md: unknown `type` values must be ignored, not treated as
        // errors — this is what lets one side ship a message first.
        let message = try decodeClient(#"{"type":"teleport","x":1}"#)
        XCTAssertEqual(message, .unknown(type: "teleport"))
    }

    func testUnknownClickActionIsUnknownNotAMisfire() throws {
        let message = try decodeClient(#"{"type":"click","button":"left","action":"triple_tap"}"#)
        XCTAssertEqual(message, .unknown(type: "click"))
    }

    func testUnknownModifierInvalidatesTheWholeKeystroke() throws {
        // Dropping the unrecognised modifier would turn this into a bare "c" —
        // doing something different from what was asked, rather than nothing.
        let message = try decodeClient(#"{"type":"key","code":"c","modifiers":["cmd","hyper"]}"#)
        XCTAssertEqual(message, .unknown(type: "key"))
    }

    func testMalformedJSONStillThrows() {
        // Ignoring unknown *messages* must not mean tolerating broken JSON.
        XCTAssertThrowsError(try decodeClient("{not json"))
    }

    // MARK: - Server → client

    func testDecodesAuthOk() throws {
        XCTAssertEqual(try decodeServer(#"{"type":"auth_ok","token":"deadbeef"}"#),
                       .authOk(token: "deadbeef"))
    }

    func testDecodesAuthFailWithAndWithoutReason() throws {
        XCTAssertEqual(try decodeServer(#"{"type":"auth_fail"}"#), .authFail(reason: nil))
        XCTAssertEqual(try decodeServer(#"{"type":"auth_fail","reason":"rate_limited"}"#),
                       .authFail(reason: .rateLimited))
    }

    func testUnrecognisedAuthFailReasonStillReadsAsAFailure() throws {
        // The client must still know the attempt failed, whatever the reason says.
        XCTAssertEqual(try decodeServer(#"{"type":"auth_fail","reason":"locked_out"}"#),
                       .authFail(reason: .other("locked_out")))
    }

    func testContextUsesCamelCaseOnTheWire() throws {
        let json = try wire(ServerMessage.context(hasSelection: true, hasClipboard: false))
        // Deliberately camelCase, unlike motion's snake_case — the real format
        // is inconsistent and the types have to match it, not tidy it up.
        XCTAssertEqual(json["hasSelection"] as? Bool, true)
        XCTAssertEqual(json["hasClipboard"] as? Bool, false)
        XCTAssertNil(json["has_selection"])
    }

    func testMissingContextFieldsFailClosed() throws {
        // ADR-0005: claiming a selection that is not there enables a Copy that
        // silently does nothing.
        XCTAssertEqual(try decodeServer(#"{"type":"context"}"#),
                       .context(hasSelection: false, hasClipboard: false))
    }

    func testMissingAccessibilityFieldReadsAsGranted() throws {
        // A server too old to send this must not be reported as broken.
        XCTAssertEqual(try decodeServer(#"{"type":"permission"}"#),
                       .permission(accessibility: true))
    }

    func testDecodesPermissionRevoked() throws {
        XCTAssertEqual(try decodeServer(#"{"type":"permission","accessibility":false}"#),
                       .permission(accessibility: false))
    }

    func testUnknownServerTypeIsIgnored() throws {
        XCTAssertEqual(try decodeServer(#"{"type":"battery","level":50}"#),
                       .unknown(type: "battery"))
    }

    // MARK: - Round trips

    func testClientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .auth(.token("t")), .auth(.pin("123456")),
            .trackpad(dx: 1.5, dy: -2.5),
            .scroll(dx: 0, dy: 18.5),
            .motion(.init(rx: 1, ry: 2, rz: 3, isLandscape: true, signX: -1, signY: 1)),
            .click(button: .right, action: .down),
            .click(button: .left, action: .doubleTap),
            .key(code: "a", modifiers: [.cmd, .shift]),
            .key(code: "escape", modifiers: []),
            .keyboard(text: "hello ✨"),
            .switchDesktop(direction: .right),
            .calibrate,
        ]
        for message in messages {
            let data = try encoder.encode(message)
            XCTAssertEqual(try decoder.decode(ClientMessage.self, from: data), message)
        }
    }

    func testServerMessagesRoundTrip() throws {
        let messages: [ServerMessage] = [
            .authOk(token: "t"),
            .authFail(reason: nil),
            .authFail(reason: .rateLimited),
            .authFail(reason: .other("nope")),
            .focusState(focused: true),
            .focusKeyboard,
            .context(hasSelection: true, hasClipboard: true),
            .permission(accessibility: false),
        ]
        for message in messages {
            let data = try encoder.encode(message)
            XCTAssertEqual(try decoder.decode(ServerMessage.self, from: data), message)
        }
    }
}
