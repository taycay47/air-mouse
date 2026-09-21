import Foundation
import Combine
import AirMouseProtocol

/// The WebSocket connection to one Mac.
///
/// Certificate validation is replaced wholesale by pinning (see TrustStore):
/// the server's certificate is self-signed and no browser or URLSession will
/// ever accept it on its own terms. This is the difference between the native
/// client and the web one — not a shortcut around a warning, but the reason the
/// warning stops existing.
@MainActor
final class Connection: NSObject, ObservableObject {

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

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var macName = ""
    private var pendingFingerprint: String?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Fails an authentication that never gets an answer. The socket can be
    /// open — or believe it is — while the Mac is simply unreachable, and
    /// without this the UI spins indefinitely with nothing to act on.
    private var authTimeout: Task<Void, Never>?
    private var lastAddress = ""
    /// Set when a certificate fails the pin. Stops the address loop: every
    /// address reaches the same Mac and would present the same certificate, and
    /// continuing would overwrite a security verdict with a generic "couldn't
    /// reach" — hiding the one thing pinning exists to surface.
    private var identityRejected = false
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

    /// Tries each address until one authenticates. Sequential rather than
    /// parallel: a successful connection pins a certificate and consumes a PIN
    /// attempt, and racing several would do both more than once.
    private func attempt(candidates: [String], port: Int, macName: String) async {
        identityRejected = false
        for address in candidates {
            guard let url = URL(string: "wss://\(address):\(port)") else { continue }
            if await open(url: url, address: address) { return }
            if identityRejected { return }
        }
        scheduleReconnect()
        state = .failed("Couldn't reach \(macName).\n\nTried: "
            + candidates.joined(separator: ", ")
            + " on port \(port).\n\nCheck that the phone and the Mac are on "
            + "the same Wi-Fi network.")
    }

    /// Opens one candidate and reports whether it got far enough to be worth
    /// keeping. Returns false quickly so the next address can be tried.
    private func open(url: URL, address: String) async -> Bool {
        lastAddress = "\(address):\(url.port ?? 8443)"

        // A delegate-backed session, because the certificate check is the whole
        // point and that only arrives through the delegate.
        let configuration = URLSessionConfiguration.ephemeral
        // Without this the handshake to an unreachable host hangs for the
        // default 60 seconds, which reads as a frozen app.
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task

        task.resume()
        receive()

        // A reachability probe, not the full handshake: send nothing, just see
        // whether the socket comes up. `ping` completes only once the WebSocket
        // is genuinely established, which is exactly the thing an unreachable
        // address never does.
        let reachable = await withCheckedContinuation { continuation in
            var resumed = false
            task.sendPing { error in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: error == nil)
            }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }
        }

        guard reachable else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            self.task = nil
            self.session = nil
            return false
        }

        authenticate()
        return true
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
            // identityChanged is excluded on purpose further down: retrying a
            // rejected certificate would loop, and it needs a human decision.
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
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .idle
    }

    /// Accepts a changed certificate and re-pairs. Only ever called from an
    /// explicit user action — this is the moment the pinning guarantee is being
    /// waived, so it must not happen on the client's own initiative.
    func acceptNewIdentity() {
        TrustStore.forget(macName)
        TokenStore.forget(macName)
        state = .idle
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
        guard let task, let data = try? encoder.encode(message) else { return }
        // A *text* frame, not binary. The server reads only text opcodes, and
        // discards binary ones silently — a client that sends binary gets no
        // error, no close, and no reply, which is indistinguishable from an
        // unreachable Mac. docs/PROTOCOL.md now states this explicitly.
        guard let json = String(data: data, encoding: .utf8) else { return }
        task.send(.string(json)) { error in
            if let error { NSLog("Air Mouse: send failed — \(error.localizedDescription)") }
        }
    }

    // MARK: - Receiving

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive()
                case .failure(let error):
                    // A cancelled task is an ordinary disconnect, not a failure
                    // worth showing.
                    guard self.task != nil else { return }
                    if self.currentMac != nil, !self.intentionallyClosed {
                        // Retry rather than stranding the user on an error
                        // screen: this fires every time the phone locks, and
                        // making them press Back and pick the Mac again for an
                        // interruption they did not cause is the wrong answer.
                        self.state = .connecting
                        self.scheduleReconnect()
                    } else {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }

        // A message that cannot be decoded at all is dropped rather than
        // surfaced: docs/PROTOCOL.md requires unknown input to be ignored, and
        // AirMouseProtocol already folds unrecognised types into `.unknown`.
        guard let message = try? decoder.decode(ServerMessage.self, from: data) else { return }

        switch message {
        case .authOk(let token):
            cancelAuthTimeout()
            // Issued on every successful auth, including token auth, so tokens
            // rotate. Always store the newest.
            TokenStore.save(token, for: macName)
            if let fingerprint = pendingFingerprint {
                TrustStore.pin(fingerprint, for: macName)
                pendingFingerprint = nil
            }
            state = .connected

        case .authFail(let reason):
            cancelAuthTimeout()
            TokenStore.forget(macName)
            state = .needsPIN(message: reason == .rateLimited
                ? "Too many attempts. Wait a moment and try again."
                : "Wrong PIN. Check the Air Mouse window on your Mac.")

        case .permission(let granted):
            accessibilityGranted = granted

        case .focusState(let focused):
            macFieldFocused = focused

        case .focusKeyboard:
            macFieldFocused = true

        case .context(let selection, let clipboard):
            hasSelection = selection
            hasClipboard = clipboard

        case .unknown:
            break
        }
    }
}

// MARK: - Certificate pinning

extension Connection: URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        Task { @MainActor in
            guard let verdict = TrustStore.verdict(for: self.macName, trust: trust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            switch verdict {
            case .matches:
                completionHandler(.useCredential, URLCredential(trust: trust))

            case .firstUse(let fingerprint):
                // Held, not written, until authentication succeeds. Pinning
                // here would record whatever answered first — including a
                // machine that cannot produce the PIN.
                self.pendingFingerprint = fingerprint
                completionHandler(.useCredential, URLCredential(trust: trust))

            case .mismatch:
                self.identityRejected = true
                self.state = .identityChanged
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
