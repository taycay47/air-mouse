import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = ServerManager()
    let permissions = PermissionsMonitor()
    let updater = UpdaterController()
    private var onboarding: OnboardingWindowController?
    private var statusPanel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar utilities don't get a Dock icon or app switcher entry.
        // Onboarding flips this to .regular while its window is open.
        NSApp.setActivationPolicy(.accessory)

        statusPanel = StatusPanelController(
            server: server,
            permissions: permissions,
            updater: updater,
            onShowSetup: { [weak self] in self?.showOnboarding() }
        )

        let onboarding = OnboardingWindowController(server: server, permissions: permissions)
        onboarding.onFinished = { [weak self] in self?.finishOnboarding() }
        self.onboarding = onboarding

        // A restart is sometimes the only way macOS will hand over a freshly granted
        // permission, so onboarding has to survive one: resume it rather than
        // dropping the user into a bare menu bar having never seen the pairing step.
        if onboardingInProgress {
            permissions.startPolling()
            if permissions.isTrusted { server.start() }
            onboarding.show()
            return
        }

        if hasCompletedOnboarding {
            // Permission can be revoked (or dropped by an OS update) long after
            // setup, in which case everything connects and nothing moves. Keep
            // watching so the menu bar can say so instead of failing silently.
            permissions.startPolling()
            server.start()
        } else {
            showOnboarding()
        }
    }

    func showOnboarding() {
        onboardingInProgress = true
        onboarding?.show()
    }

    func finishOnboarding() {
        onboardingInProgress = false
        hasCompletedOnboarding = true
    }

    /// Onboarding is "done" once permission has been granted at least once —
    /// there is nothing else in it the user needs to repeat.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Survives a relaunch, so a restart mid-flow resumes instead of skipping it.
    var onboardingInProgress: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingInProgress") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingInProgress") }
    }
}

/// Plain AppKit entry point, not a SwiftUI `App`.
///
/// Everything this app shows is owned by the delegate — the status panel and
/// the onboarding window — and a SwiftUI `App` insists on at least one scene
/// of its own. The only one that shows nothing is `Settings`, and that one
/// still appeared, as an empty "Air Mouse Settings" window, whenever the app
/// was activated with no other window open.
@main
@MainActor
enum AirMouseBarMain {
    /// NSApplication holds its delegate weakly; this keeps it alive.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
