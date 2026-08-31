import Foundation

// Ported from mouse_controller.py's pairing/auth section: a PIN regenerated on
// every server start, paired tokens persisted to disk, global (not per-connection)
// rate limiting on failed attempts — see docs/PROTOCOL.md's port note on keeping
// rate limiting global, since per-connection limiting is trivially defeated by
// reconnecting.
final class AuthState {
    let pin: String
    private let tokensFileURL: URL
    private var pairedTokens: Set<String>
    private var failTimes: [Double] = []
    private let maxFails = 20
    private let windowSeconds: Double = 60.0

    init(appSupportDir: URL) {
        self.pin = String(format: "%06d", Int.random(in: 0..<1_000_000))
        self.tokensFileURL = appSupportDir.appendingPathComponent("paired_devices.json")
        self.pairedTokens = AuthState.loadTokens(from: tokensFileURL)
    }

    enum Result {
        case ok(token: String)
        case failRateLimited
        case failInvalid
    }

    func attempt(token: String?, pin candidatePin: String?) -> Result {
        if isRateLimited() {
            return .failRateLimited
        }
        if let token = token, pairedTokens.contains(token) {
            return .ok(token: token)
        }
        if let candidatePin = candidatePin, candidatePin == pin {
            let newToken = UUID().uuidString + UUID().uuidString
            saveToken(newToken)
            return .ok(token: newToken)
        }
        recordFailure()
        return .failInvalid
    }

    private static func loadTokens(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String]
        else {
            return []
        }
        return Set(tokens)
    }

    private func saveToken(_ token: String) {
        pairedTokens.insert(token)
        let obj: [String: Any] = ["tokens": pairedTokens.sorted()]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: tokensFileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokensFileURL.path)
    }

    private func isRateLimited() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        failTimes.removeAll { now - $0 > windowSeconds }
        return failTimes.count >= maxFails
    }

    private func recordFailure() {
        failTimes.append(ProcessInfo.processInfo.systemUptime)
    }
}
