import SwiftUI

/// The PIN, large enough to read from across a desk, copyable with one click.
struct PinCard: View {
    let pin: String
    var size: CGFloat = 26
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pin, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 10) {
                Text(pin.map(String.init).joined(separator: " "))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.opacity)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, size * 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface()
        .help("Copy PIN")
        .accessibilityLabel("PIN \(pin). Copy")
    }
}

/// The web client's way in, for a phone without the app. Kept out of sight
/// until asked for: the native app finds this Mac by itself.
struct BrowserPairing: View {
    let url: String

    var body: some View {
        VStack(spacing: 8) {
            if let qr = qrImage(for: url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(url)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
    }
}
