import Foundation
import Network
import Security

/// WebSocket over TLS over TCP, spoken by Network.framework rather than
/// URLSession.
///
/// The same bytes to the same server — Network.framework performs the HTTP
/// upgrade itself — but with the knobs URLSession does not expose:
///
///   - **`noDelay`**. Nagle's algorithm holds a small write back waiting for a
///     bigger one. Every packet this app sends is small and every one of them is
///     urgent, which is precisely the case Nagle was designed to defeat. With
///     URLSession we could only hope it was off.
///   - **Service class and peer-to-peer**, as on every channel.
///   - **A connection that survives a path change** instead of dying, so
///     walking between Wi-Fi bands does not force a reconnect.
final class ReliableTransport: Transport {
    let kind: TransportKind = .reliable
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onReady: (() -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.airmouse.reliable")
    private var closed = false

    init(host: String, port: Int, verify: @escaping (SecTrust) -> Bool) {
        let tls = TransportParameters.pinnedTLS(verify: verify)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Without this an unreachable address sits in `.preparing` far longer
        // than a person will wait, and every candidate address after it waits
        // behind that.
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        TransportParameters.common(parameters)

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        // A URL endpoint, not host-and-port. `NWProtocolWebSocket` builds its
        // upgrade request from the endpoint, and given a bare host and port it
        // never sends one: the TCP connection opens, the server accepts it, and
        // the handshake simply never completes. That failure is silent on both
        // sides and looks exactly like an unreachable Mac.
        //
        // Brackets for an IPv6 literal, which is only a URL host with them.
        let literal = host.contains(":") ? "[\(host)]" : host
        let url = URL(string: "wss://\(literal):\(port)/")
        connection = NWConnection(
            to: url.map { NWEndpoint.url($0) }
                ?? .hostPort(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(integerLiteral: UInt16(port))),
            using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.onReady?() }
                self.receive()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            case .waiting(let error):
                // Waiting means no route. Reported rather than waited out: the
                // candidate loop has other addresses to try.
                self.finish(error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        // A *text* frame. The server reads only text opcodes and drops binary
        // ones silently, which is indistinguishable from an unreachable Mac —
        // a whole evening was once lost to exactly that.
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, completion: .idempotent)
    }

    func cancel() {
        closed = true
        connection.cancel()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                self.finish(nil)
                return
            }
            if let data, !data.isEmpty {
                Task { @MainActor in self.onData?(data) }
            }
            if let error {
                self.finish(error.localizedDescription)
                return
            }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        Task { @MainActor in self.onClose?(reason) }
    }
}

/// DTLS over UDP: the input stream's channel.
///
/// Reached by Bonjour service first and by address second. The service endpoint
/// is what lets the system choose a direct peer-to-peer radio link; the address
/// is what works when it cannot. Both lead to the same listener on the Mac, so
/// whichever answers first is the right one.
final class DatagramTransport: Transport {
    let kind: TransportKind = .fast
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onReady: (() -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.airmouse.fast")
    private var closed = false

    /// - Parameter viaService: prefer the Bonjour instance over the raw port.
    init?(offer: FastChannelOffer, host: String, viaService: Bool) {
        guard let key = Data(base64Encoded: offer.key) else { return nil }
        let parameters = TransportParameters.presharedDTLS(key: key, identity: offer.identity)

        let endpoint: NWEndpoint
        if viaService, let service = offer.service {
            endpoint = .service(name: service,
                                type: FastChannelOffer.serviceType,
                                domain: "local",
                                interface: nil)
        } else {
            endpoint = .hostPort(host: NWEndpoint.Host(host),
                                 port: NWEndpoint.Port(integerLiteral: UInt16(offer.port)))
        }
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.onReady?() }
                self.receive()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        // `.idempotent` rather than a completion handler: there is nothing
        // useful to do about a datagram that did not go out, and the next one
        // is already a few milliseconds away.
        connection.send(content: data, completion: .idempotent)
    }

    func cancel() {
        closed = true
        connection.cancel()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in self.onData?(data) }
            }
            if error != nil {
                self.finish(error?.localizedDescription)
                return
            }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        Task { @MainActor in self.onClose?(reason) }
    }
}

/// The Mac's offer of a fast channel, as it arrives on the reliable one.
struct FastChannelOffer {
    static let serviceType = "_airmouse-fast._udp"

    var port: Int
    var key: String
    var identity: String
    var service: String?
}
