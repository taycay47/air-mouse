import Foundation
import AirMouseProtocol

/// Everything the action button can do, defined once.
///
/// The set is a *list*, not a layout: the panel renders whatever
/// `ActionSettings.visible` contains, in that order, and knows nothing about
/// which actions exist. That is the whole point — a configuration screen in the
/// style of Safari's Customize Toolbar is then a view that reorders an array of
/// strings, with no other part of the app to change.
///
/// Two consequences worth keeping:
///   - ids are stable strings, not enum ordinals, so a stored arrangement
///     survives actions being added or reordered in this file;
///   - an id the catalog no longer knows is dropped on read rather than
///     crashing, so removing an action here cannot corrupt anybody's layout.
struct ActionItem: Identifiable, Equatable {
    let id: String
    /// Used by the configuration screen and by VoiceOver. The button itself
    /// shows only the icon.
    let title: String
    let icon: String
    let message: ClientMessage
}

enum ActionCatalog {
    /// Absent on purpose:
    ///
    ///   - **Brightness.** macOS stopped honouring `NX_KEYTYPE_BRIGHTNESS` from
    ///     synthetic events; it now lives behind a private framework. A button
    ///     that does nothing is worse than no button.
    ///   - **Dictation / Siri.** Dictation is bound to a double-press of a
    ///     modifier key, which is not a keystroke and cannot be sent as one.
    ///
    /// Both can return the day there is an honest way to send them.
    static let all: [ActionItem] = [
        .init(id: "mission_control", title: "Mission Control",
              icon: "macwindow.on.rectangle",
              message: .key(code: "missioncontrol", modifiers: [])),
        .init(id: "spotlight", title: "Spotlight",
              icon: "magnifyingglass",
              message: .key(code: "space", modifiers: [.cmd])),
        .init(id: "escape", title: "Escape",
              icon: "escape",
              message: .key(code: "escape", modifiers: [])),

        .init(id: "previous", title: "Previous",
              icon: "backward.fill",
              message: .key(code: "previoustrack", modifiers: [])),
        .init(id: "playpause", title: "Play / Pause",
              icon: "playpause.fill",
              message: .key(code: "playpause", modifiers: [])),
        .init(id: "next", title: "Next",
              icon: "forward.fill",
              message: .key(code: "nexttrack", modifiers: [])),

        .init(id: "mute", title: "Mute",
              icon: "speaker.slash.fill",
              message: .key(code: "mute", modifiers: [])),
        .init(id: "volume_down", title: "Volume Down",
              icon: "speaker.wave.1.fill",
              message: .key(code: "volumedown", modifiers: [])),
        .init(id: "volume_up", title: "Volume Up",
              icon: "speaker.wave.3.fill",
              message: .key(code: "volumeup", modifiers: [])),

        // Reachable here as well as on the pills, so the two places that can
        // invoke Copy agree on what Copy is.
        .init(id: "copy", title: "Copy",
              icon: "doc.on.doc",
              message: .key(code: "c", modifiers: [.cmd])),
        .init(id: "paste", title: "Paste",
              icon: "doc.on.clipboard",
              message: .key(code: "v", modifiers: [.cmd])),
        .init(id: "undo", title: "Undo",
              icon: "arrow.uturn.backward",
              message: .key(code: "z", modifiers: [.cmd])),
        .init(id: "select_all", title: "Select All",
              icon: "selection.pin.in.out",
              message: .key(code: "a", modifiers: [.cmd])),
    ]

    /// Three rows of three: the function-row essentials, grouped the way the
    /// function row groups them. The rest of the catalogue is available but off
    /// by default — Copy and Paste already appear on their own when the Mac says
    /// they would do something.
    static let defaultArrangement = [
        "mission_control", "spotlight", "escape",
        "previous", "playpause", "next",
        "mute", "volume_down", "volume_up",
    ]

    static func item(_ id: String) -> ActionItem? {
        all.first { $0.id == id }
    }
}

/// Which actions are on the panel, and in what order.
///
/// Persisted now, editable later. The store exists at this stage so that adding
/// the configuration screen is additive rather than a refactor of every view
/// that shows an action.
final class ActionSettings: ObservableObject {
    private static let key = "actions.arrangement"

    @Published var arrangement: [String] {
        didSet { UserDefaults.standard.set(arrangement, forKey: Self.key) }
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key)
        arrangement = stored ?? ActionCatalog.defaultArrangement
    }

    /// Unknown ids are skipped rather than treated as an error: an arrangement
    /// saved by a newer build must still open in an older one.
    var visible: [ActionItem] {
        arrangement.compactMap(ActionCatalog.item)
    }

    func reset() {
        arrangement = ActionCatalog.defaultArrangement
    }
}
