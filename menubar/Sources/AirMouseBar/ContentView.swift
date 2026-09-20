import SwiftUI

struct ContentView: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var permissions: PermissionsMonitor
    @ObservedObject var updater: UpdaterController
    var onShowSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(server.statusMessage)
                    .font(.headline)
            }

            // Without this the failure is silent: the phone connects, the UI looks
            // healthy, and nothing moves. See docs/ROADMAP.md step 4.
            if !permissions.isTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Accessibility permission missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).bold()
                        .foregroundStyle(.orange)
                    Text("Your phone can connect, but Air Mouse can't move the cursor or type until this is granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Fix this…") { onShowSetup() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
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
                Button("Setup…") { onShowSetup() }
            }

            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
                Button("Quit") {
                    server.stop()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 240)
    }
}
