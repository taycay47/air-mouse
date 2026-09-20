import AppKit
import SwiftUI

/// Hosts the onboarding flow in a real window.
///
/// Done with AppKit rather than a SwiftUI `Window` scene because this is an
/// `LSUIElement` app: it has no Dock icon, so it cannot be activated normally.
/// Showing a focusable window means switching to `.regular` while it is open and
/// back to `.accessory` when it closes, which needs direct control over both the
/// window's lifetime and the activation policy.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let server: ServerManager
    private let permissions: PermissionsMonitor
    /// Called when the user finishes the flow, so the "in progress" state that
    /// survives a relaunch can be cleared.
    var onFinished: (() -> Void)?

    init(server: ServerManager, permissions: PermissionsMonitor) {
        self.server = server
        self.permissions = permissions
    }

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView(server: server, permissions: permissions) { [weak self] in
            self?.onFinished?()
            self?.close()
        }

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Air Mouse"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // A Dock icon is needed for the window to be able to take focus at all.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app.
        NSApp.setActivationPolicy(.accessory)
        permissions.stopPolling()
    }
}
