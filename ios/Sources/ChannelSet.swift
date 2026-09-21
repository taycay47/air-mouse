import Foundation
import Combine
import AirMouseProtocol

/// Every channel that is up, and the rule for which one carries what.
///
/// The premise is to hold open as many routes to the Mac as the network will
/// allow and use the best of them, rather than picking one at connect time and
/// living with it. A channel that is already up is a channel that can be fallen
/// back to in the time it takes to call `send`, with no handshake, no timeout
/// and nothing for the user to notice.
///
/// Two channels, in practice: one reliable (`ReliableTransport`, or
/// `CompatTransport` where that fails) and one unreliable (`DatagramTransport`).
/// They are not alternatives — they are used at the same time, for different
/// things.
@MainActor
final class ChannelSet: ObservableObject {

    /// Where the input stream is currently going. `reliable` until the fast
    /// channel has proved itself with a round trip.
    @Published private(set) var streamKind: TransportKind = .reliable
    /// Round-trip time of each live channel, in milliseconds. Published so the
    /// interface can express the quality of the link rather than only its
    /// existence.
    @Published private(set) var rtt: [TransportKind: Double] = [:]

    var fastestRTT: Double? { rtt[streamKind] }

    private var reliable: Transport?
    private var fast: DatagramTransport?
    private var onMessage: ((ServerMessage) -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Outstanding probes, by id, with the time they went out.
    private var probes: [UInt32: (kind: TransportKind, sent: CFAbsoluteTime)] = [:]
    private var nextProbeID: UInt32 = 1
    private var prober: Timer?
    /// Unanswered probes in a row on the fast channel. Three is roughly three
    /// seconds of silence, which is far longer than a busy network's worst
    /// honest delay and far shorter than a person's patience.
    private var fastMisses = 0
    private let missesBeforeDemotion = 3

    /// Whether a mouse button is currently held.
    ///
    /// While it is, movement goes over the reliable channel even though the
    /// fast one is open. The two channels have independent latency, and a
    /// `mouse down` that lands after the movement it was meant to precede
    /// starts the drag in the wrong place — a selection from nowhere to
    /// somewhere. Inferred from the message stream rather than wired in from
    /// the gesture engine, so nothing else has to know this rule exists.
    private var buttonHeld = false

    // MARK: - Lifecycle

    func adopt(_ transport: Transport, onMessage: @escaping (ServerMessage) -> Void) {
        self.onMessage = onMessage
        reliable = transport
        streamKind = transport.kind
        transport.onData = { [weak self] data in self?.receive(data, from: transport.kind) }
        startProbing()
    }

    func closeAll() {
        prober?.invalidate()
        prober = nil
        fast?.cancel()
        fast = nil
        reliable?.cancel()
        reliable = nil
        probes.removeAll()
        rtt.removeAll()
        fastMisses = 0
        buttonHeld = false
    }

    /// Brings up the unreliable channel the Mac just offered.
    ///
    /// Tried by Bonjour service first, since that is the form that lets the
    /// system pick a direct peer-to-peer link, and by address if the service
    /// does not come up. Failure at any point is silent and harmless: the
    /// reliable channel is already carrying everything.
    func openFast(offer: FastChannelOffer, host: String, viaService: Bool = true) {
        fast?.cancel()
        fast = nil
        guard let transport = DatagramTransport(
            offer: offer, host: host, viaService: viaService) else { return }
        fast = transport
        transport.onData = { [weak self] data in self?.receive(data, from: .fast) }
        transport.onReady = { [weak self] in
            // Ready means the DTLS handshake completed, not that packets are
            // getting through. Nothing is routed here until a probe comes back.
            self?.probe(on: .fast)
        }
        transport.onClose = { [weak self] _ in
            guard let self, self.fast === transport else { return }
            self.demoteFast()
            // One retry, by address, in case the Bonjour route was the problem.
            if viaService {
                self.openFast(offer: offer, host: host, viaService: false)
            }
        }
        transport.start()
    }

    // MARK: - Sending

    func send(_ message: ClientMessage) {
        track(message)
        guard let data = try? encoder.encode(message) else { return }
        transport(for: message)?.send(data)
    }

    /// The routing rule, in one place.
    ///
    /// Movement is the only thing that goes over the unreliable channel, and it
    /// is the only thing that should: a dropped delta costs a few pixels that
    /// the next one corrects, while a dropped click costs a click. Everything
    /// else — keystrokes, buttons, auth — is unrepeatable and stays where
    /// delivery is guaranteed.
    private func transport(for message: ClientMessage) -> Transport? {
        switch message {
        case .trackpad, .scroll, .motion:
            if streamKind == .fast, !buttonHeld, let fast { return fast }
            return reliable
        case .ping:
            return nil // routed explicitly by `probe`
        default:
            return reliable
        }
    }

    private func track(_ message: ClientMessage) {
        guard case .click(_, let action) = message else { return }
        switch action {
        case .down: buttonHeld = true
        case .up: buttonHeld = false
        case .tap, .doubleTap: break // atomic: never leaves a button held
        }
    }

    // MARK: - Receiving

    private func receive(_ data: Data, from kind: TransportKind) {
        guard let message = try? decoder.decode(ServerMessage.self, from: data) else { return }
        if case .pong(let id) = message {
            complete(probe: id, on: kind)
            return
        }
        onMessage?(message)
    }

    // MARK: - Measurement

    /// Probes every live channel once a second.
    ///
    /// This is the only way to know which channel is actually better. Choosing
    /// UDP because it is theoretically faster, without checking, would be a
    /// guess dressed as an optimisation — and on a network where UDP is
    /// silently dropped it would be a guess that broke the app.
    private func startProbing() {
        prober?.invalidate()
        prober = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeAll() }
        }
        probeAll()
    }

    private func probeAll() {
        expireStaleProbes()
        if let reliable { probe(on: reliable.kind) }
        if fast != nil { probe(on: .fast) }
    }

    private func probe(on kind: TransportKind) {
        let id = nextProbeID
        nextProbeID &+= 1
        probes[id] = (kind, CFAbsoluteTimeGetCurrent())
        guard let data = try? encoder.encode(ClientMessage.ping(id: id)) else { return }
        switch kind {
        case .fast: fast?.send(data)
        default: reliable?.send(data)
        }
    }

    private func complete(probe id: UInt32, on kind: TransportKind) {
        guard let sent = probes.removeValue(forKey: id) else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - sent.sent) * 1000
        // Smoothed, because a single sample is mostly noise and this drives
        // something the user can see.
        let previous = rtt[kind]
        rtt[kind] = previous.map { $0 * 0.7 + elapsed * 0.3 } ?? elapsed

        guard kind == .fast else { return }
        fastMisses = 0
        if streamKind != .fast {
            // Proven, not assumed: the channel has now carried a message to the
            // Mac and back.
            streamKind = .fast
        }
    }

    private func expireStaleProbes() {
        let now = CFAbsoluteTimeGetCurrent()
        let stale = probes.filter { now - $0.value.sent > 2.0 }
        for (id, probe) in stale {
            probes.removeValue(forKey: id)
            guard probe.kind == .fast else { continue }
            fastMisses += 1
            if fastMisses >= missesBeforeDemotion { demoteFast() }
        }
    }

    /// Falls back to the reliable channel, instantly and without a handshake.
    ///
    /// This is the whole reason both channels stay open. Demotion costs one
    /// assignment; re-establishing a connection here would cost a visible
    /// stall in the middle of somebody moving a cursor.
    private func demoteFast() {
        guard streamKind == .fast else { return }
        streamKind = reliable?.kind ?? .reliable
        rtt[.fast] = nil
        fastMisses = 0
    }
}
