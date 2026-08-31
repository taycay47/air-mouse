import Foundation
import AirMouseServerCore

/// Owns the AirMouseServerCore server in-process (not a spawned child binary).
///
/// This replaces both the earlier Python `mouse_controller.py` child process and
/// an earlier Swift attempt that spawned a separate `AirMouseServer` binary — see
/// docs/adr/0002-port-input-injection-from-python-to-swift.md. Both of those
/// shapes reintroduce the exact problem ADR-0002 set out to fix: Accessibility
/// permission ends up granted to a separate, unstable child binary instead of
/// this app itself. Running the server in-process means one binary, one grant.
final class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var pin: String?
    @Published var url: String?
    @Published var statusMessage = "Stopped"

    private let runner = AirMouseServerRunner()
    private let port = 8443

    /// Repo root, resolved relative to this source file's own location at compile
    /// time (`#filePath`) rather than a hardcoded path — consistent with how
    /// toggle_mouse_server.sh and the Raycast extension locate the checkout.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ServerManager.swift -> AirMouseBar/
            .deletingLastPathComponent() // AirMouseBar/ -> Sources/
            .deletingLastPathComponent() // Sources/ -> menubar/
            .deletingLastPathComponent() // menubar/ -> repo root
    }

    private var webRoot: URL { repoRoot.appendingPathComponent("web", isDirectory: true) }

    func start() {
        guard !isRunning else { return }
        statusMessage = "Starting…"

        let runner = self.runner
        let port = self.port
        let webRoot = self.webRoot

        // The initial bind briefly blocks the calling thread — run it off the
        // main thread so it can't stall the UI. The server itself then runs on
        // its own event loop thread regardless of which thread started it.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let appSupportDir = try appSupportDirectory()
                let info = try runner.start(port: port, webRoot: webRoot, appSupportDir: appSupportDir)
                DispatchQueue.main.async { [weak self] in
                    self?.pin = info.pin
                    self?.url = info.url
                    self?.isRunning = true
                    self?.statusMessage = "Running"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.statusMessage = "Failed to start: \(error)"
                }
            }
        }
    }

    func stop() {
        runner.stop()
        isRunning = false
        pin = nil
        url = nil
        statusMessage = "Stopped"
    }
}
