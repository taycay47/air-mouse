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

    // MARK: - Lifecycle

    func connect(to mac: Discovery.Mac, host: String, port: Int) {
        disconnect()
        macName = mac.name
        state = .connecting

        guard let url = URL(string: "wss://\(host):\(port)") else {
            state = .failed("Bad address for \(mac.name)")
            return
        }

        // A delegate-backed session, because the certificate check is the whole
        // point and that only arrives through the delegate.
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task

        task.resume()
        receive()
        authenticate()
    }

    func disconnect() {
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
        state = .authenticating
        if let token = TokenStore.token(for: macName) {
            send(.auth(.token(token)))
        } else {
            state = .needsPIN(message: nil)
        }
    }

    func submit(pin: String) {
        state = .authenticating
        send(.auth(.pin(pin)))
    }

    // MARK: - Sending

    func send(_ message: ClientMessage) {
        guard let task, let data = try? encoder.encode(message) else { return }
        task.send(.data(data)) { error in
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
                    if self.task != nil {
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
            // Issued on every successful auth, including token auth, so tokens
            // rotate. Always store the newest.
            TokenStore.save(token, for: macName)
            if let fingerprint = pendingFingerprint {
                TrustStore.pin(fingerprint, for: macName)
                pendingFingerprint = nil
            }
            state = .connected

        case .authFail(let reason):
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
                self.state = .identityChanged
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
