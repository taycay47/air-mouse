import Foundation

/// URLSession's WebSocket — the transport the web client used.
///
/// Kept, and tried last, because it is the one most likely to work when the
/// others do not: it is the most ordinary thing on the network, so a captive
/// portal, a corporate profile or a firewall that blocks UDP and mangles raw
/// TLS will usually still let this through. A fallback nobody ever reaches is
/// only worth having if it is *different* from what it falls back from, and
/// this one is.
final class CompatTransport: NSObject, Transport {
    let kind: TransportKind = .compat
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onReady: (() -> Void)?

    private let url: URL
    private let verify: @Sendable (SecTrust) -> Bool
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    init(host: String, port: Int, verify: @escaping @Sendable (SecTrust) -> Bool) {
        self.url = URL(string: "wss://\(host):\(port)") ?? URL(string: "wss://127.0.0.1")!
        self.verify = verify
    }

    func start() {
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

        // `sendPing` completes only once the WebSocket is genuinely established,
        // which is exactly what an unreachable address never does. It is the
        // readiness signal URLSession otherwise does not give.
        task.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(error.localizedDescription)
            } else {
                Task { @MainActor in self.onReady?() }
            }
        }
    }

    func send(_ data: Data) {
        guard let json = String(data: data, encoding: .utf8) else { return }
        // A *text* frame, not binary: the server discards binary opcodes
        // silently, with no error and no close — indistinguishable from an
        // unreachable Mac.
        task?.send(.string(json)) { _ in }
    }

    func cancel() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = nil
                }
                if let data { Task { @MainActor in self.onData?(data) } }
                self.receive()
            case .failure(let error):
                self.finish(error.localizedDescription)
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        Task { @MainActor in self.onClose?(reason) }
    }
}

extension CompatTransport: URLSessionDelegate {
    func urlSession(
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
        if verify(trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
