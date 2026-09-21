import Foundation
import Combine
import Security
import AirMouseProtocol

/// The connection to one Mac.
///
/// Certificate validation is replaced wholesale by pinning (see TrustStore):
/// the server's certificate is self-signed and no browser or URLSession will
/// ever accept it on its own terms. This is the difference between the native
/// client and the web one — not a shortcut around a warning, but the reason the
/// warning stops existing.
///
/// This type owns *what* is said. `ChannelSet` owns *how* it gets there, over
/// however many channels are currently up.
@MainActor
final class Connection: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        /// Connected, certificate accepted, waiting to authenticate.
        case authenticating
        case connected
        /// Needs the six-digit PIN shown on the Mac.
        case needsPIN(message: String?)
        case failed(String)
        /// The Mac presented a different certificate than the pinned one.
        /// Deliberately its own state: silently re-pinning would defeat the
        /// point, and folding it into `failed` would leave no way to accept a
        /// legitimate regeneration.
        case identityChanged
    }

    @Published private(set) var state: State = .idle

    /// Whether messages are actually reaching the Mac. Drives the grid's tint,
    /// which is this interface's only connection indicator.
    var isLive: Bool { state == .connected }
    @Published private(set) var accessibilityGranted = true
    @Published private(set) var macFieldFocused = false
    @Published private(set) var hasSelection = false
    @Published private(set) var hasClipboard = false

    /// Every open channel, and the choice between them.
    let channels = ChannelSet()

    private var macName = ""
    private var pinning = PinRecorder()

    /// Fails an authentication that never gets an answer. The socket can be
    /// open — or believe it is — while the Mac is simply unreachable, and
    /// without this the UI spins indefinitely with nothing to act on.
    private var authTimeout: Task<Void, Never>?
    private var lastAddress = ""
    private var currentHost = ""
    /// The Mac to return to. Kept so a dropped connection — the phone locking,
    /// the app backgrounding, Wi-Fi blinking — can be retried without making
    /// the user pick it out of a list again.
    private var currentMac: Discovery.Mac?
    private var reconnect: Task<Void, Never>?
    /// Set while the user is deliberately leaving, so teardown is not mistaken
    /// for a drop worth retrying.
    private var intentionallyClosed = false

    // MARK: - Lifecycle

    func connect(to mac: Discovery.Mac) {
        disconnect()
        intentionallyClosed = false
        currentMac = mac
        macName = mac.name
        state = .connecting

        // Every address the Mac advertised, tried in order. Discovery finding a
        // Mac does not mean this phone has a route to it: Bonjour travels over a
        // USB link that carries no route to the Mac's Wi-Fi address, and the
        // hostname resolves to whichever interface mDNS feels like naming.
        //
        // Trying raw addresses is only acceptable because of pinning. Ordinary
        // TLS would reject an IP that does not match the certificate's names;
        // here the certificate is compared by fingerprint, so which name was
        // dialled is irrelevant.
        let port = mac.port ?? 8443
        let candidates = mac.candidates
        guard !candidates.isEmpty else {
            state = .failed("\(mac.name) didn't publish an address. "
                + "Restart Air Mouse on the Mac and try again.")
            return
        }

        Task { await attempt(candidates: candidates, port: port, macName: mac.name) }
    }

    /// Tries each address until one connects. Sequential rather than parallel: a
    /// successful connection pins a certificate and consumes a PIN attempt, and
    /// racing several would do both more than once.
    private func attempt(candidates: [String], port: Int, macName: String) async {
        pinning.reset()
        for address in candidates {
            if await open(host: address, port: port) { return }
            // Every address reaches the same Mac and would present the same
            // certificate, so a pinning refusal ends the loop rather than being
            // overwritten by a generic "couldn't reach" from the next address —
            // which would hide the one thing pinning exists to surface.
            if pinning.rejected {
                state = .identityChanged
                return
            }
        }
        scheduleReconnect()
        state = .failed("Couldn't reach \(macName).\n\nTried: "
            + candidates.joined(separator: ", ")
            + " on port \(port).\n\nCheck that the phone and the Mac are on "
            + "the same Wi-Fi network.")
    }

    /// Opens one address over the best transport that will carry it.
    ///
    /// `ReliableTransport` first — Nagle off, voice service class, peer-to-peer
    /// allowed — and URLSession's WebSocket only if that fails. The fallback is
    /// worth having because it is *different*: the most ordinary thing on the
    /// network, and therefore the most likely to survive a network that objects
    /// to the rest.
    private func open(host: String, port: Int) async -> Bool {
        lastAddress = "\(host):\(port)"
        currentHost = host

        let verify = pinning.verifier(for: macName)
        let candidates: [Transport] = [
            ReliableTransport(host: host, port: port, verify: verify),
            CompatTransport(host: host, port: port, verify: verify),
        ]

        for transport in candidates {
            if await bringUp(transport) {
                adopt(transport)
                return true
            }
            transport.cancel()
            if pinning.rejected { return false }
        }
        return false
    }

    /// Resolves as soon as the transport is usable, or gives up on it.
    private func bringUp(_ transport: Transport) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            let settle: (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            transport.onReady = { settle(true) }
            transport.onClose = { _ in settle(false) }
            transport.start()

            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                settle(false)
            }
        }
    }

    private func adopt(_ transport: Transport) {
        // Replaced now that the transport is live: `bringUp`'s handlers were
        // only ever about whether it came up.
        transport.onReady = nil
        transport.onClose = { [weak self] _ in self?.channelDropped() }
        channels.adopt(transport) { [weak self] message in
            self?.handle(message)
        }
        authenticate()
    }

    private func channelDropped() {
        guard !intentionallyClosed, currentMac != nil else { return }
        // Retry rather than stranding the user on an error screen: this fires
        // every time the phone locks, and making them press Back and pick the
        // Mac again for an interruption they did not cause is the wrong answer.
        state = .connecting
        scheduleReconnect()
    }

    /// Returns to the picker from a failure, without tearing anything down —
    /// there is nothing to tear down, and `disconnect` would also clear the
    /// message the user is being asked to read.
    func reset() {
        intentionallyClosed = true
        cancelReconnect()
        currentMac = nil
        state = .idle
    }

    /// Releases any button the Mac is holding on this connection's behalf.
    ///
    /// Sent on the way to the background, where the app stops getting touch
    /// events entirely — including the `up` that would end a drag.
    func releaseHeldInput() {
        send(.click(button: .left, action: .up))
    }

    /// Reconnects to the Mac already chosen, if any. Called when the app comes
    /// back to the foreground and after a drop.
    func reconnectIfNeeded() {
        guard !intentionallyClosed, let mac = currentMac else { return }
        switch state {
        case .connected, .connecting, .authenticating, .needsPIN:
            return
        case .idle, .failed, .identityChanged:
            // identityChanged is excluded on purpose: retrying a rejected
            // certificate would loop, and it needs a human decision.
            guard state != .identityChanged else { return }
            connect(to: mac)
        }
    }

    private func scheduleReconnect() {
        guard !intentionallyClosed, currentMac != nil else { return }
        cancelReconnect()
        reconnect = Task { [weak self] in
            // Matches the web client's retry cadence. Long enough not to hammer
            // a sleeping Mac, short enough that waking the phone feels instant.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.reconnectIfNeeded()
        }
    }

    private func cancelReconnect() {
        reconnect?.cancel()
        reconnect = nil
    }

    func disconnect() {
        cancelAuthTimeout()
        cancelReconnect()
        channels.closeAll()
        state = .idle
    }

    /// Accepts a changed certificate and re-pairs. Only ever called from an
    /// explicit user action — this is the moment the pinning guarantee is being
    /// waived, so it must not happen on the client's own initiative.
    func acceptNewIdentity() {
        TrustStore.forget(macName)
        TokenStore.forget(macName)
        pinning.reset()
        state = .idle
        // Reconnects straight away rather than waiting for discovery to change:
        // the Mac is already known, and nothing is going to change to trigger
        // it now that there is no device list to return to.
        reconnectIfNeeded()
    }

    // MARK: - Auth

    private func authenticate() {
        if let token = TokenStore.token(for: macName) {
            state = .authenticating
            send(.auth(.token(token)))
            armAuthTimeout()
        } else {
            // Not a timed state: it waits on the user, not on the network.
            state = .needsPIN(message: nil)
        }
    }

    func submit(pin: String) {
        state = .authenticating
        send(.auth(.pin(pin)))
        armAuthTimeout()
    }

    private func armAuthTimeout() {
        authTimeout?.cancel()
        authTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, case .authenticating = self.state else { return }
            self.state = .failed("No answer from \(self.macName) at \(self.lastAddress). It was found on the network but can't be reached — usually that means the phone and the Mac are on different Wi-Fi networks.")
        }
    }

    private func cancelAuthTimeout() {
        authTimeout?.cancel()
        authTimeout = nil
    }

    // MARK: - Sending

    func send(_ message: ClientMessage) {
        channels.send(message)
    }

    // MARK: - Receiving

    private func handle(_ message: ServerMessage) {
        switch message {
        case .authOk(let token):
            cancelAuthTimeout()
            // Issued on every successful auth, including token auth, so tokens
            // rotate. Always store the newest.
            TokenStore.save(token, for: macName)
            pinning.commit(for: macName)
            state = .connected

        case .authFail(let reason):
            cancelAuthTimeout()
            TokenStore.forget(macName)
            state = .needsPIN(message: reason == .rateLimited
                ? "Too many attempts. Wait a moment and try again."
                : "Wrong PIN. Check the Air Mouse window on your Mac.")

        case .fastChannel(let offer):
            // Only ever acted on after authentication: before that there is no
            // session for it to belong to, and the offer would be coming from
            // something that has not proved it is the Mac.
            guard state == .connected else { return }
            channels.openFast(
                offer: FastChannelOffer(port: offer.port,
                                        key: offer.key,
                                        identity: offer.identity,
                                        service: offer.service),
                host: currentHost)

        case .permission(let granted):
            accessibilityGranted = granted

        case .focusState(let focused):
            macFieldFocused = focused

        case .focusKeyboard:
            macFieldFocused = true

        case .context(let selection, let clipboard):
            hasSelection = selection
            hasClipboard = clipboard

        case .pong:
            break // consumed by ChannelSet, which timed it

        case .unknown:
            break
        }
    }
}

// MARK: - Certificate pinning

/// The pinning verdict, reachable from whichever thread a transport does its
/// TLS handshake on.
///
/// Both transports verify the same way and record the same outcome here; the
/// connection reads it later, on the main actor. The lock exists because
/// Network.framework's verify block and URLSession's delegate run on their own
/// queues and neither offers a choice about it.
final class PinRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: String?
    private var refused = false

    var rejected: Bool {
        lock.lock(); defer { lock.unlock() }
        return refused
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
        refused = false
    }

    /// Writes the held fingerprint, if any.
    ///
    /// Called on `auth_ok` and nowhere else: pinning at handshake time would
    /// record whatever answered first, including a machine that cannot produce
    /// the PIN.
    func commit(for mac: String) {
        lock.lock()
        let fingerprint = pending
        pending = nil
        lock.unlock()
        if let fingerprint { TrustStore.pin(fingerprint, for: mac) }
    }

    func verifier(for mac: String) -> @Sendable (SecTrust) -> Bool {
        { [self] trust in
            guard let verdict = TrustStore.verdict(for: mac, trust: trust) else { return false }
            switch verdict {
            case .matches:
                return true
            case .firstUse(let fingerprint):
                lock.lock()
                pending = fingerprint
                lock.unlock()
                return true
            case .mismatch:
                lock.lock()
                refused = true
                lock.unlock()
                return false
            }
        }
    }
}
