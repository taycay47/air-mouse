import Foundation

/// Launches and supervises the existing Python `mouse_controller.py` server as a
/// child process, and parses its startup banner for the pairing PIN and URL.
///
/// This is a v1 wrapper, not a native reimplementation: the Swift app owns the
/// menu bar UI and process lifecycle, but mouse/keyboard injection still happens
/// in the Python/CoreGraphics server. Porting that to native Swift/CoreGraphics
/// calls is future work — see menubar/README.md.
final class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var pin: String?
    @Published var url: String?
    @Published var statusMessage = "Stopped"

    private var process: Process?
    private var outputPipe: Pipe?

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

    private var pythonPath: URL { repoRoot.appendingPathComponent(".venv/bin/python3") }
    private var scriptPath: URL { repoRoot.appendingPathComponent("mouse_controller.py") }

    func start() {
        guard process == nil else { return }
        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            statusMessage = "venv not found — run setup in Terminal first"
            return
        }

        let proc = Process()
        proc.executableURL = pythonPath
        proc.arguments = [scriptPath.path]
        proc.currentDirectoryURL = repoRoot

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.parse(output: text) }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.statusMessage = "Stopped"
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            statusMessage = "Starting…"
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
        isRunning = false
        pin = nil
        url = nil
        statusMessage = "Stopped"
    }

    private func parse(output: String) {
        if let pinRange = output.range(of: #"PAIRING PIN:\s*(\d{4,6})"#, options: .regularExpression) {
            pin = String(output[pinRange]).split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        if let urlRange = output.range(of: #"https://[^\s]+"#, options: .regularExpression) {
            url = String(output[urlRange])
            statusMessage = "Running"
        }
    }
}
