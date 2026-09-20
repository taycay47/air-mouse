import Foundation
import AppKit
import ApplicationServices

/// Tracks whether this app has Accessibility permission, which it needs in order
/// to post any input at all.
///
/// Polls rather than making the user confirm: the grant is made in System
/// Settings, and macOS gives no notification when it happens. Per docs/ROADMAP.md
/// step 3, onboarding must advance on its own — never ask the user to come back
/// and click "I did it".
@MainActor
final class PermissionsMonitor: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var timer: Timer?

    /// Asks macOS to show its own Accessibility prompt.
    ///
    /// This is also what registers the app with TCC and gets it listed in System
    /// Settings at all — an app that has never asked simply isn't in the list, so
    /// there is no switch to turn on. Do **not** open System Settings in the same
    /// user action: that steals focus and suppresses this dialog, which lands the
    /// user in a list their app was never added to.
    ///
    /// Silent after the first time for a given app identity, hence
    /// `openSystemSettings()` and `revealInFinder()` as fallbacks.
    func requestAccess() {
        NSApp.activate(ignoringOtherApps: true)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Last-resort route: if the app never got listed, the user can add it with
    /// the "+" button, and dragging it in from Finder is the least painful way.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // Unwrapped before the Task rather than inside it. Reaching through
            // `self?` from within a concurrently-executing closure is an error on
            // Swift 5.x — it compiles on 6.3 locally and fails on the CI runner,
            // which is the older toolchain.
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        // .common so polling continues while a menu is open or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        // AXIsProcessTrusted() is the only reliable signal here.
        //
        // Do not "verify" it by attempting an Accessibility read as a fallback: a
        // process can always read its *own* AX tree without permission, so probing
        // the system-wide focused element succeeds trivially whenever this app's own
        // window is frontmost — which is exactly when onboarding is on screen. That
        // reported permission as granted immediately after it had been revoked.
        //
        // This call can lag behind a grant made while the app is running; the restart
        // path in onboarding covers that case rather than a cleverer check.
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        if trusted {
            stopPolling()
        }
    }

    /// Relaunches the app.
    ///
    /// macOS may not surface a new Accessibility grant to a running process at all,
    /// in which case restarting is the only way through — and making the app do it
    /// is far better than telling the user to quit and reopen it themselves.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
