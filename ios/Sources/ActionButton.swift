import SwiftUI
import AirMouseProtocol

/// The function row, behind one button.
///
/// What is on it comes from `ActionSettings`, not from here: this view renders
/// an array and has no opinion about its contents. A Customize-Toolbar screen
/// later edits that array and this file does not change.
///
/// Icons only, no labels. These are the same glyphs as the keys they stand for —
/// a phone held in one hand at arm's length is read by shape, and a row of text
/// labels at this size is read by nobody.
///
/// On iOS 26 the button and the panel share a `glassEffectID`, so the system
/// morphs one into the other: the glass stretches open and settles rather than
/// one view fading out while another fades in. That is the reason to use Liquid
/// Glass here rather than a material — it can express that the panel *is* the
/// button, which a cross-fade cannot.
struct ActionButton: View {
    @ObservedObject var settings: ActionSettings
    /// Owned by the screen, not by this view: the touch surface closes the
    /// panel too, and a panel that only its own button could dismiss stayed
    /// open behind every gesture that followed.
    @Binding var isOpen: Bool
    let send: (ClientMessage) -> Void
    let haptics: Haptics
    let onFired: () -> Void

    @Namespace private var glass

    /// Three across, which is what the groupings are: system, transport,
    /// volume. Also the widest a panel can be and still sit in the corner it
    /// opened from.
    private let columns = 3

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 14) { content }
            } else {
                content
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: isOpen)
    }

    @ViewBuilder
    private var content: some View {
        if isOpen && !settings.visible.isEmpty {
            panel
        } else {
            trigger
        }
    }

    private var trigger: some View {
        Button {
            isOpen = true
            haptics.play(.tap)
        } label: {
            Image(systemName: "command")
                .font(.system(size: 18, weight: .medium))
                .frame(width: ControlMetrics.size, height: ControlMetrics.size)
        }
        .foregroundStyle(.white)
        .glassSurface(in: Circle())
        .glassMorphID("actions", in: glass)
        .accessibilityLabel("Actions")
    }

    private var panel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { action in
                        button(for: action)
                    }
                }
            }

            // Closing sits where the trigger was, so the button appears to
            // stay put while the panel grows out of it. Firing an action does
            // *not* close: volume and transport are pressed repeatedly.
            Button {
                isOpen = false
                haptics.play(.tap)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: ControlMetrics.size, height: ControlMetrics.size)
            }
            .foregroundStyle(.white.opacity(0.7))
            .accessibilityLabel("Close actions")
        }
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26), interactive: false)
        .glassMorphID("actions", in: glass)
    }

    private func button(for action: ActionItem) -> some View {
        Button {
            send(action.message)
            haptics.play(.tap)
            onFired()
        } label: {
            Image(systemName: action.icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: ControlMetrics.size, height: ControlMetrics.size)
        }
        .foregroundStyle(.white)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel(action.title)
    }

    private var rows: [[ActionItem]] {
        let items = settings.visible
        return stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
    }
}

/// Shared control sizing, so the buttons that sit beside each other actually
/// match. They did not: the one that opened the keyboard and the one that
/// dismissed it were different sizes and on opposite sides.
enum ControlMetrics {
    static let size: CGFloat = 46
}

extension View {
    /// Ties a view to a morph identity, where the OS supports it.
    ///
    /// Two views sharing an id and a namespace are treated as the same piece of
    /// glass in different shapes, so the system interpolates between them
    /// instead of cross-fading.
    @ViewBuilder
    func glassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}
