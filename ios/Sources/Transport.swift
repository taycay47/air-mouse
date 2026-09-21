import Foundation
import Network
import Security

/// One way of getting bytes to the Mac.
///
/// There are three, and the app opens as many of them as it can rather than
/// choosing one at connect time: a channel that is up is a channel that can be
/// fallen back to instantly, and a channel that is measurably faster can be
/// promoted the moment it proves itself. See `ChannelSet`.
protocol Transport: AnyObject {
    var kind: TransportKind { get }
    /// Called on the main actor with each decoded message payload.
    var onData: ((Data) -> Void)? { get set }
    /// Called once, on the main actor, when the channel goes away for good.
    var onClose: ((String?) -> Void)? { get set }
    /// Called on the main actor the first time the channel is usable.
    var onReady: (() -> Void)? { get set }

    func start()
    func send(_ data: Data)
    func cancel()
}

enum TransportKind: String, Comparable {
    /// URLSession's WebSocket. The transport the web client used, kept because
    /// it is the one that works when everything else is blocked.
    case compat
    /// Network.framework speaking WebSocket over pinned TLS: Nagle off, voice
    /// service class, peer-to-peer allowed.
    case reliable
    /// DTLS over UDP. No retransmission, no head-of-line blocking.
    case fast

    /// Higher is better. `ChannelSet` sends over the best channel that is live.
    private var rank: Int {
        switch self {
        case .compat: return 0
        case .reliable: return 1
        case .fast: return 2
        }
    }

    static func < (a: TransportKind, b: TransportKind) -> Bool { a.rank < b.rank }

    var label: String {
        switch self {
        case .compat: return "TCP (compat)"
        case .reliable: return "TCP"
        case .fast: return "UDP"
        }
    }
}

// MARK: - Shared parameter construction

enum TransportParameters {

    /// Applied to every channel.
    ///
    /// `serviceClass = .interactiveVoice` is the cheapest real win available
    /// here: it marks the packets for Wi-Fi's voice access category, which on a
    /// congested access point is a genuine queue-jump ahead of somebody else's
    /// video. `includePeerToPeer` lets the system consider a direct AWDL link
    /// to the Mac — the AirDrop mechanism — instead of competing for airtime on
    /// the access point at all. Neither is a guarantee; both are free.
    static func common(_ parameters: NWParameters) {
        parameters.serviceClass = .interactiveVoice
        parameters.includePeerToPeer = true
    }

    /// TLS that trusts exactly one certificate: the pinned one.
    ///
    /// The same verdict the URLSession path reaches, through a different door.
    /// `sec_trust_copy_ref` is what turns Network.framework's opaque trust
    /// object back into the `SecTrust` the TrustStore already knows how to read.
    static func pinnedTLS(verify: @escaping (SecTrust) -> Bool) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let queue = DispatchQueue(label: "com.airmouse.tls-verify")
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                complete(verify(secTrust))
            },
            queue)
        return tls
    }

    /// DTLS authenticated by a key both ends already share.
    ///
    /// No certificate: the key arrived over the pinned, authenticated TCP
    /// connection, so completing this handshake proves the same thing a
    /// certificate would, without needing a `SecIdentity` on the Mac.
    static func presharedDTLS(key: Data, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let ident = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, psk as __DispatchData, ident as __DispatchData)
        // Network.framework's DTLS stops at 1.2, where PSK needs its own
        // ciphersuite; TLS 1.3 folded PSK into the ordinary ones. Spelled out
        // by value because the Swift enum has no case for it.
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
        common(parameters)
        return parameters
    }
}
