import Foundation
import dnssd
import AirMouseCore

/// Advertises the running server over Bonjour, so the phone can find this Mac
/// without a QR code (docs/ROADMAP.md step 5).
///
/// Built on `DNSServiceRegister` rather than `NetService` or `NWListener`:
///
/// - `NWListener` owns the socket it advertises, and this server's socket
///   belongs to NIO. Handing the port to Network framework to get discovery
///   would mean replacing the whole listener — the same dead end ADR-0002
///   already walked down for TLS.
/// - `NetService` is the classic API for advertising a port you already own,
///   but it is soft-deprecated and run-loop bound.
///
/// `DNSServiceRegister` is the layer both of those sit on: it advertises a port
/// without caring who is listening on it, and `DNSServiceSetDispatchQueue`
/// keeps it off the run loop.
public final class BonjourAdvertiser {
    /// Registered service type. The `_airmouse` name is ours; anything a client
    /// browses for has to match this exactly.
    public static let serviceType = "_airmouse._tcp"

    private var serviceRef: DNSServiceRef?
    private let queue = DispatchQueue(label: "com.airmouse.bonjour")

    public init() {}

    /// Starts advertising. Safe to call again — the previous registration is
    /// withdrawn first, which is what makes this correct across a server
    /// restart on a different port.
    ///
    /// - Parameter name: what the phone shows in a device list. Empty means
    ///   "use the computer's name", which mDNSResponder resolves itself and
    ///   keeps correct if the user renames their Mac.
    @discardableResult
    public func start(port: Int, name: String = "") -> Bool {
        stop()

        // TXT records are unauthenticated — everything here is a hint, never
        // something to make a trust decision on. A spoofed `host` cannot do
        // harm: the client pins the certificate, and a certificate for the
        // wrong machine fails that check.
        //
        // `host` and `port` are carried here so a client can build its URL
        // straight from a browse result. The alternative is resolving the
        // endpoint through a throwaway connection purely to read back the host
        // and port, which is a lot of machinery for two strings the server
        // already knows.
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }

        func setTXT(_ key: String, _ value: String) {
            _ = value.withCString { pointer in
                TXTRecordSetValue(&txt, key, UInt8(strlen(pointer)), pointer)
            }
        }
        setTXT("v", "1")
        setTXT("host", localHostname())
        setTXT("port", String(port))
        // Every address this Mac answers on, so the client can try them rather
        // than depending on one name resolving to a route that exists. A phone
        // on Wi-Fi and a phone tethered over USB reach this machine on entirely
        // different addresses, and mDNS resolution of the hostname does not
        // reliably pick the one the phone can actually route to.
        setTXT("addrs", lanIPv4Addresses().joined(separator: ","))

        var ref: DNSServiceRef?
        let status = DNSServiceRegister(
            &ref,
            0,                                  // no flags: rename automatically on conflict
            0,                                  // all interfaces
            name.isEmpty ? nil : name,
            Self.serviceType,
            nil,                                // default domain (.local)
            nil,                                // host: let mDNSResponder use this machine's
            in_port_t(port).bigEndian,          // the API takes network byte order
            TXTRecordGetLength(&txt),
            TXTRecordGetBytesPtr(&txt),
            nil,                                // no callback: registration failures surface below
            nil
        )

        guard status == kDNSServiceErr_NoError, let ref else {
            logError("Bonjour registration failed with status \(status)")
            return false
        }

        DNSServiceSetDispatchQueue(ref, queue)
        serviceRef = ref
        return true
    }

    /// Withdraws the advertisement. Called on stop and on deinit, so a stopped
    /// server does not keep answering browse queries for a port nothing is
    /// listening on — a phone that connects to a stale record just hangs.
    public func stop() {
        guard let ref = serviceRef else { return }
        DNSServiceRefDeallocate(ref)
        serviceRef = nil
    }

    deinit {
        stop()
    }
}
