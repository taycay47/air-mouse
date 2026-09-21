import Foundation
import CryptoKit
import Security

/// Remembers which certificate each Mac presented the first time, and refuses
/// anything else afterwards — trust on first use, the same model as SSH host
/// keys.
///
/// This is what removes the browser's certificate warning rather than coaching
/// people through it. The server's certificate is self-signed, so no public
/// authority can vouch for it and no amount of certificate hygiene will make a
/// browser accept it. Pinning sidesteps the question: the client does not care
/// who signed it, only that it is the same one as last time.
///
/// The honest limitation: the *first* connection is unverified. An attacker
/// already positioned on the network at that exact moment could be pinned
/// instead of the real Mac. Every connection after that is protected, and the
/// PIN — which the attacker cannot see — is what stops that first connection
/// from being useful to them.
enum TrustStore {

    /// Fingerprints are public information, not secrets, so UserDefaults is the
    /// right home. The pairing token is a different matter and lives in the
    /// keychain (see TokenStore).
    private static let defaults = UserDefaults.standard
    private static func key(for mac: String) -> String { "pinned-cert::\(mac)" }

    enum Verdict {
        /// Nothing pinned yet: this is the first connection.
        case firstUse(fingerprint: String)
        case matches
        /// A different certificate than the one pinned. Either the Mac
        /// regenerated its certificate, or this is not the same Mac.
        case mismatch(pinned: String, presented: String)
    }

    static func verdict(for mac: String, trust: SecTrust) -> Verdict? {
        guard let presented = fingerprint(of: trust) else { return nil }
        guard let pinned = defaults.string(forKey: key(for: mac)) else {
            return .firstUse(fingerprint: presented)
        }
        return pinned == presented ? .matches : .mismatch(pinned: pinned, presented: presented)
    }

    static func pin(_ fingerprint: String, for mac: String) {
        defaults.set(fingerprint, forKey: key(for: mac))
    }

    static func forget(_ mac: String) {
        defaults.removeObject(forKey: key(for: mac))
    }

    /// SHA-256 over the leaf certificate's DER.
    ///
    /// The whole certificate rather than just its public key: the server
    /// generates a fresh key every time it regenerates (`openssl req -newkey`),
    /// so pinning the key would break on regeneration exactly as pinning the
    /// certificate does. Given that, the simpler thing to hash is the better one.
    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// The pairing token, which grants control of the Mac and therefore belongs in
/// the keychain rather than UserDefaults.
enum TokenStore {
    private static let service = "com.airmouse.remote.pairing-token"

    static func token(for mac: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mac,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for mac: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mac,
        ]
        // Delete-then-add rather than update: SecItemUpdate fails when there is
        // nothing to update, which makes the first save a special case for no
        // benefit.
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        // The Mac is on the local network, so there is no reason to reach it
        // before the phone has been unlocked once since boot.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func forget(_ mac: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mac,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
