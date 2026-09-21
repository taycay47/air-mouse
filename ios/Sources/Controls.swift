import SwiftUI
import AirMouseProtocol

/// Copy and Paste, shown only when the Mac says they would do something.
///
/// Driven entirely by the `context` message. The Mac reports unknown state as
/// false rather than omitting it (ADR-0005), so a pill that cannot be offered
/// honestly is simply not offered — a Copy button that silently does nothing is
/// worse than no Copy button.
struct ContextPills: View {
    let hasSelection: Bool
    let hasClipboard: Bool
    let send: (ClientMessage) -> Void
    let haptics: Haptics

    var body: some View {
        HStack(spacing: 10) {
            if hasSelection {
                pill("Copy", icon: "doc.on.doc") {
                    send(.key(code: "c", modifiers: [.cmd]))
                }
                .transition(.scale.combined(with: .opacity))
            }
            if hasClipboard {
                pill("Paste", icon: "doc.on.clipboard") {
                    send(.key(code: "v", modifiers: [.cmd]))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8),
                   value: [hasSelection, hasClipboard])
    }

    private func pill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            haptics.play(.tap)
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassSurface(in: Capsule())
        }
        .foregroundStyle(.white)
    }
}

/// Live keyboard passthrough.
///
/// Every character goes to the Mac as it is typed, and the field keeps what was
/// typed rather than clearing itself — so nothing is silently lost if the Mac
/// had no text field focused. Deletion is sent as an explicit `backspace` key
/// rather than as text, which is what the protocol requires.
struct KeyboardBar: View {
    @Binding var text: String
    let macFieldFocused: Bool
    let send: (ClientMessage) -> Void
    let haptics: Haptics
    let onDone: () -> Void

    /// What the Mac has already been sent. The diff against `text` is what
    /// turns an edited field into keystrokes.
    @State private var sent = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Type to your Mac", text: $text, axis: .horizontal)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                // An explicit height rather than vertical padding, so the field
                // and the button beside it are the same size. Padding around
                // text of a different size never matches a fixed frame.
                .frame(height: ControlMetrics.size)
                .glassSurface(in: Capsule(), interactive: false)
                // Dimmed when the Mac has no text field focused: a hint that
                // this will go nowhere useful, never a block on sending
                // (ADR-0004).
                .overlay(Capsule().strokeBorder(
                    macFieldFocused ? .white.opacity(0.35) : .clear,
                    lineWidth: 1))
                // The single-argument form deliberately: the two-argument
                // onChange is iOS 17+, and the deployment floor is 16 so the
                // app still runs on an iPhone 8.
                .onChange(of: text) { new in transmit(new) }

            Button {
                isFocused = false
                onDone()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: ControlMetrics.size, height: ControlMetrics.size)
            }
            .foregroundStyle(.white)
            .glassSurface(in: Circle())
        }
        .padding(.horizontal, 16)
        .onAppear { isFocused = true }
    }

    /// Sends only what changed, as the smallest sequence of keystrokes that
    /// gets the Mac from `sent` to `new`.
    private func transmit(_ new: String) {
        if new.hasPrefix(sent) {
            let added = String(new.dropFirst(sent.count))
            if !added.isEmpty { send(.keyboard(text: added)) }
        } else {
            // Something was deleted, or edited mid-string. Walk back to the
            // common prefix with backspaces, then type the remainder.
            let common = commonPrefix(sent, new)
            for _ in 0..<(sent.count - common.count) {
                send(.key(code: "backspace", modifiers: []))
            }
            let added = String(new.dropFirst(common.count))
            if !added.isEmpty { send(.keyboard(text: added)) }
        }
        sent = new
        haptics.play(.scrollDetent)
    }

    private func commonPrefix(_ a: String, _ b: String) -> String {
        String(zip(a, b).prefix { $0 == $1 }.map(\.0))
    }
}
