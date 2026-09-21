import Foundation
import Network
import Combine

/// Finds Macs running Air Mouse on the local network, replacing the QR code
/// (docs/ROADMAP.md step 5).
///
/// The server advertises `_airmouse._tcp` (see BonjourAdvertiser.swift) and
/// resolves to `<host>.local`, which is also a name the server's certificate
/// carries a subjectAltName for — so connecting to what discovery returns gives
/// a certificate that actually validates, rather than one that cannot match.
@MainActor
final class Discovery: ObservableObject {

    struct Mac: Identifiable, Equatable {
        /// The Bonjour instance name, e.g. "MacBook Pro von Robert". This is
        /// what the user picks from, and mDNSResponder guarantees it is unique
        /// on the network — it appends "(2)" on a conflict.
        let name: String
        let endpoint: NWEndpoint
        /// From the service's TXT record. Unauthenticated, and safe to be so:
        /// connecting to a spoofed host fails certificate pinning, which is
        /// what actually establishes identity.
        let host: String?
        let port: Int?
        var id: String { name }

        static func == (lhs: Mac, rhs: Mac) -> Bool {
            lhs.name == rhs.name && lhs.host == rhs.host && lhs.port == rhs.port
        }
    }

    @Published private(set) var macs: [Mac] = []
    @Published private(set) var isSearching = false
    /// Set when browsing fails outright, which on iOS almost always means the
    /// local-network permission was denied rather than anything about the network.
    @Published private(set) var failure: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        // Otherwise the browser will not see a server running on this same Mac
        // when the client is the simulator, which is the only way to test
        // discovery without a second machine.
        parameters.includePeerToPeer = true

        // bonjourWithTXTRecord, not plain .bonjour: the plain descriptor never
        // populates Result.metadata, so every result arrives with no TXT at all
        // and the host/port the server publishes are silently invisible.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BonjourService.type, domain: nil),
            using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                    self.failure = nil
                case .failed(let error):
                    self.isSearching = false
                    // iOS reports a denied local-network permission as a browse
                    // failure, not as a permission error, so say the useful
                    // thing rather than the literal one.
                    self.failure = "Can't search the local network. "
                        + "Check Settings › Air Mouse › Local Network. (\(error))"
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.macs = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    var host: String?
                    var port: Int?
                    if case let .bonjour(txt) = result.metadata {
                        host = txt["host"]
                        port = txt["port"].flatMap(Int.init)
                    }
                    return Mac(name: name, endpoint: result.endpoint, host: host, port: port)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}

enum BonjourService {
    /// Must match BonjourAdvertiser.serviceType on the Mac exactly, and must
    /// also appear in the app's NSBonjourServices, or browsing silently returns
    /// nothing at all.
    static let type = "_airmouse._tcp"
}
