import Foundation
import AppKit

/// Drives the "Uninstall…" button.
///
/// An app cannot finish removing itself while it is running, so this does not
/// try. It hands the work to `reset_install.sh` — the same script used from the
/// terminal, so there is one definition of what "installed" means — and quits.
/// The script waits for this process to exit before it touches anything.
///
/// The script is copied to a temporary directory before being run. It ships
/// inside `Contents/Resources`, and bash reads a script incrementally as it
/// executes: deleting the bundle out from under a running script invites it to
/// misbehave partway through. A copy outside the bundle has no such problem.
@MainActor
enum Uninstaller {

    enum Failure: LocalizedError {
        case scriptMissing
        case copyFailed(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing:
                return "This build has no uninstall script bundled."
            case .copyFailed(let why):
                return "Could not prepare the uninstaller: \(why)"
            case .launchFailed(let why):
                return "Could not start the uninstaller: \(why)"
            }
        }
    }

    /// Shows the confirmation, and on approval starts the uninstaller and quits.
    static func confirmAndRun(server: ServerManager) {
        guard confirm() else { return }

        do {
            let logURL = try launch()
            // Quitting is what lets the script proceed — it is blocked on this
            // process exiting. Stop the server first so the port is released and
            // any held mouse button is dropped (ADR-0006).
            server.stop()
            NSLog("Air Mouse: uninstaller started, log at \(logURL.path)")
            NSApp.terminate(nil)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Confirmation

    private static func confirm() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall Air Mouse?"
        alert.informativeText = """
            This removes the app, its certificate and paired devices, its \
            preferences, and its Accessibility and Automation permissions. \
            Air Mouse will quit.

            Your phone keeps its saved pairing until you clear Safari's website \
            data for this Mac, and the Home Screen icon has to be deleted there \
            by hand.

            This cannot be undone.
            """
        // First button is the default; make the destructive one deliberate by
        // putting Cancel there instead.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall")
        alert.buttons.last?.hasDestructiveAction = true

        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Launching

    /// Copies the script out of the bundle and starts it detached. Returns the
    /// log file it is writing to.
    private static func launch() throws -> URL {
        guard let bundled = Bundle.main.url(forResource: "reset_install", withExtension: "sh") else {
            throw Failure.scriptMissing
        }

        let tempDir = FileManager.default.temporaryDirectory
        let scriptCopy = tempDir.appendingPathComponent("airmouse-uninstall-\(UUID().uuidString).sh")
        let logURL = tempDir.appendingPathComponent("airmouse-uninstall.log")

        do {
            try FileManager.default.copyItem(at: bundled, to: scriptCopy)
        } catch {
            throw Failure.copyFailed(error.localizedDescription)
        }

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw Failure.launchFailed("could not open \(logURL.path)")
        }

        let process = Process()
        // Invoked through bash rather than executed directly, so the copy does
        // not depend on the execute bit surviving the bundle and the copy.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptCopy.path,
            "--yes",
            "--wait-for-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--app-path", Bundle.main.bundleURL.path,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        // When this app exits the script is reparented to launchd and carries
        // on; NSApp.terminate does not signal the child. Verified empirically —
        // the whole feature rests on it.
        process.qualityOfService = .userInitiated

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        return logURL
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
