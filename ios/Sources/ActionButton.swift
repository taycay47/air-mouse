import SwiftUI
import AirMouseProtocol

/// Keyboard shortcuts, behind one button.
///
/// The web client kept these in a settings sheet, and the first native pass put
/// them in a row that was always on screen — eight chips permanently occupying
/// the bottom of a surface whose whole point is to be empty. They are used
/// occasionally; they should be reachable, not resident.
///
/// On iOS 26 the button and the panel share a `glassEffectID`, so the system
/// morphs one into the other: the glass stretches open and settles rather than
/// one view fading out while another fades in. That is the reason to use Liquid
/// Glass here rather than a material — it can express that the panel *is* the
/// button, which a cross-fade cannot.
struct ActionButton: View {
    let send: (ClientMessage) -> Void
    let haptics: Haptics
    let onFired: () -> Void

    @State private var isOpen = false
    @Namespace private var glass

    private struct Shortcut: Identifiable {
        let id = UUID()
        let label: String
        let code: String
        let modifiers: [KeyModifier]
    }

    private let shortcuts: [Shortcut] = [
        .init(label: "⌘C", code: "c", modifiers: [.cmd]),
        .init(label: "⌘V", code: "v", modifiers: [.cmd]),
        .init(label: "⌘X", code: "x", modifiers: [.cmd]),
        .init(label: "⌘Z", code: "z", modifiers: [.cmd]),
        .init(label: "⌘A", code: "a", modifiers: [.cmd]),
        .init(label: "⌘Tab", code: "tab", modifiers: [.cmd]),
        .init(label: "⌘Space", code: "space", modifiers: [.cmd]),
        .init(label: "⎋", code: "escape", modifiers: []),
        .init(label: "⏎", code: "enter", modifiers: []),
        .init(label: "⌫", code: "backspace", modifiers: []),
    ]

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
        if isOpen {
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
    }

    private var panel: some View {
        VStack(spacing: 10) {
            // Two rows of five rather than one scrolling strip: every shortcut
            // is reachable without hunting, and a horizontal scroller hides
            // whatever it cannot fit.
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { shortcut in
                        Button {
                            send(.key(code: shortcut.code, modifiers: shortcut.modifiers))
                            haptics.play(.tap)
                            onFired()
                        } label: {
                            Text(shortcut.label)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                        .foregroundStyle(.white)
                        .glassSurface(in: RoundedRectangle(cornerRadius: 11))
                    }
                }
            }

            Button {
                isOpen = false
                haptics.play(.tap)
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .foregroundStyle(.white)
            .glassSurface(in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .glassSurface(in: RoundedRectangle(cornerRadius: 24), interactive: false)
        .glassMorphID("actions", in: glass)
        .padding(.horizontal, 16)
    }

    private var rows: [[Shortcut]] {
        stride(from: 0, to: shortcuts.count, by: 5).map {
            Array(shortcuts[$0..<min($0 + 5, shortcuts.count)])
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
