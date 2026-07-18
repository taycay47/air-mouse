import SwiftUI

struct ContentView: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(server.statusMessage)
                    .font(.headline)
            }

            if let urlString = server.url, let pin = server.pin {
                if let qr = qrImage(for: urlString) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 160, height: 160)
                        .padding(.vertical, 4)
                }

                HStack {
                    Text("PIN:")
                        .foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pin, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                }

                Text(urlString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            HStack {
                if server.isRunning {
                    Button("Stop Server", role: .destructive) { server.stop() }
                } else {
                    Button("Start Server") { server.start() }
                }
                Spacer()
                Button("Quit") {
                    server.stop()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}
