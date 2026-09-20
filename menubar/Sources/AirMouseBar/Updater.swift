import Foundation
import Combine
import Sparkle

/// Wraps Sparkle so the menu bar can offer "Check for Updates…" and reflect
/// whether a check is currently possible.
///
/// Updates matter more than usual for this app: Accessibility permission is
/// remembered against the app's code signature, so an update that ships under a
/// different signature silently revokes it — the phone still pairs and nothing
/// moves. In-place updates via Sparkle under a stable Developer ID keep the
/// grant intact. See ADR-0009.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true begins the scheduled background check. With no
        // SUFeedURL configured yet this is inert rather than fatal.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
