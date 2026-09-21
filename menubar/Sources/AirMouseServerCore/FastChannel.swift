import Foundation
import Network
import Security
import AirMouseCore

/// A second, unreliable channel for the input stream.
///
/// TCP promises delivery and ordering. For cursor deltas that is the wrong
/// promise: a delta that arrives 150ms late is worse than one that never
/// arrives, because the cursor freezes and then jumps. On a congested access
/// point one lost packet stalls every packet behind it until the retransmit
/// lands — head-of-line blocking — and that stall is exactly what "laggy on a
/// busy network" feels like.
///
/// Over UDP a lost delta is simply lost, and the next one corrects the small
/// error it left. There are no sequence numbers here on purpose: deltas add, and
/// addition commutes, so two movement packets arriving out of order produce the
/// same cursor position as in-order. Only loss matters, and loss is the thing we
/// are choosing to accept.
///
/// Security is DTLS with a pre-shared key rather than a certificate. The key is
/// 32 fresh bytes per session, handed to the phone over the connection that has
/// already authenticated and pinned the Mac's certificate — so completing this
/// handshake *is* the authentication, and there is no second PIN, token or
/// replay window to get wrong. It also avoids turning the PEM files into a
/// `SecIdentity`, which Network.framework would otherwise require.
///
/// Reachable two ways, and it advertises both: a Bonjour service, which lets
/// macOS pick the path — including a direct AWDL radio link to the phone,
/// bypassing the access point entirely — and a plain port for when it does not.
final class FastChannel {

    /// A packet, and the way to answer on the channel it came in on.
    typealias Handler = (_ packet: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void

    /// Known only once the listener is ready, which is why the offer is sent
    /// from a callback rather than returned from `init`.
    private(set) var port: Int = 0
    /// Base64, as it goes on the wire.
    let key: String
    let identity: String
    let serviceName: String

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.airmouse.fast")
    private var connections: [NWConnection] = []
    private let handler: Handler

    init?(handler: @escaping Handler, onReady: @escaping (FastChannel) -> Void) {
        self.handler = handler

        var secret = Data(count: 32)
        let ok = secret.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!) == errSecSuccess
        }
        guard ok else { return nil }

        // Distinct per session, so a stale phone holding an old key cannot
        // complete a handshake against a new one.
        let identity = UUID().uuidString
        self.key = secret.base64EncodedString()
        self.identity = identity
        self.serviceName = "airmouse-" + identity.prefix(8)

        guard let listener = try? NWListener(
            using: FastChannel.parameters(secret: secret, identity: identity))
        else { return nil }
        self.listener = listener

        listener.service = NWListener.Service(
            name: serviceName, type: FastChannel.serviceType)

        // The port is only known once the listener is ready, and waiting for it
        // would block the event loop that is currently mid-authentication. So
        // the offer is sent from here, later, instead of being returned.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let resolved = listener.port else { return }
                self.port = Int(resolved.rawValue)
                onReady(self)
            case .failed(let error):
                logError("[Fast] listener failed: \(error) — staying on TCP")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    static let serviceType = "_airmouse-fast._udp"

    private static func parameters(secret: Data, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let ident = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, key as __DispatchData, ident as __DispatchData)
        // DTLS tops out at 1.2 in Network.framework, where a PSK handshake needs
        // an explicit PSK ciphersuite — TLS 1.3 would have folded this into the
        // ordinary suites. The constant is spelled out because the Swift enum
        // has no case for it.
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
        // Wi-Fi's voice access category. On a congested access point this is a
        // real queue-jump ahead of somebody's video download, and it costs one
        // line.
        parameters.serviceClass = .interactiveVoice
        parameters.includePeerToPeer = true
        return parameters
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handler(packet) { [weak connection] reply in
                    guard let connection,
                          let payload = try? JSONSerialization.data(withJSONObject: reply)
                    else { return }
                    connection.send(content: payload, completion: .idempotent)
                }
            }
            guard error == nil else { return }
            self.receive(on: connection)
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
