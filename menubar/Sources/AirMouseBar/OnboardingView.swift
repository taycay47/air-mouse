import SwiftUI
import AppKit

/// First-run flow: explain, get Accessibility, then hand over the pairing details.
///
/// The permission step advances by itself as soon as the grant lands
/// (docs/ROADMAP.md step 3), and the pairing step coaches through the
/// self-signed-certificate warning, which is otherwise the point where a
/// first-time user assumes the app is broken.
struct OnboardingView: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var permissions: PermissionsMonitor
    var onFinish: () -> Void

    private enum Step {
        case welcome, accessibility, pairing
    }

    @State private var step: Step = .welcome
    /// Shown only after waiting a while, so the normal path stays uncluttered.
    @State private var showRestartHint = false
    @State private var waitTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460)
        .onAppear {
            permissions.startPolling()
            // Coming back from a restart that was needed to pick up the grant:
            // don't make the user walk the whole flow again.
            if permissions.isTrusted {
                advanceToPairing()
            } else if step == .accessibility {
                startWaitTimer()
            }
        }
        .onDisappear {
            waitTimer?.invalidate()
            waitTimer = nil
        }
        .onChange(of: permissions.isTrusted) { trusted in
            // Auto-advance the moment the grant appears.
            if trusted && step == .accessibility {
                advanceToPairing()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            welcome
        case .accessibility:
            accessibility
        case .pairing:
            pairing
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Use your phone as a trackpad")
                .font(.title2).bold()

            Text("Air Mouse runs a small server on this Mac. Your phone opens a web page over your local network — nothing to install on the phone, and nothing leaves your network.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Two things to set up: permission to control this Mac, then pairing your phone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Continue") {
                    step = permissions.isTrusted ? .pairing : .accessibility
                    if permissions.isTrusted { startServerIfNeeded() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: permissions.isTrusted ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 40))
                .foregroundStyle(permissions.isTrusted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))

            Text("Allow Air Mouse to control your Mac")
                .font(.title2).bold()

            Text("Moving the cursor and typing counts as controlling your Mac, so macOS requires you to grant Accessibility permission. It cannot be granted from inside the app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                stepLine(1, "Click **Allow Access** below. macOS asks for confirmation.")
                stepLine(2, "In that dialog, choose **Open System Settings**.")
                stepLine(3, "Turn on the switch next to **Air Mouse**.")
                stepLine(4, "Come back here. This window continues on its own.")
            }
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                Button("Allow Access") {
                    // Deliberately does not also open System Settings: doing both in
                    // one action suppresses the macOS dialog, and that dialog is what
                    // registers the app so it appears in the list at all.
                    permissions.requestAccess()
                    startWaitTimer()
                }
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for permission…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)

            if showRestartHint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Already turned it on?")
                        .font(.callout).bold()
                    Text("macOS sometimes won't hand a new permission to an app that's already running. Restarting picks it up — you'll land right back here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Restart Air Mouse") { permissions.relaunch() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Don't see Air Mouse in the list?")
                    .font(.callout).bold()
                Text("macOS only lists apps that have asked. If it's still missing, add it by hand: click **+** in the Accessibility list and choose Air Mouse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Open System Settings") { permissions.openSystemSettings() }
                        .controlSize(.small)
                    Button("Reveal Air Mouse in Finder") { permissions.revealInFinder() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair your phone")
                .font(.title2).bold()

            if let urlString = server.url, let pin = server.pin {
                HStack(alignment: .top, spacing: 20) {
                    if let qr = qrImage(for: urlString) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        stepLine(1, "Scan this code with your phone's camera.")
                        stepLine(2, "Safari will warn about the certificate. Tap **Show Details → Visit this Website**. It is expected: the connection is encrypted with a certificate this Mac generated for itself, which no public authority can vouch for.")
                        stepLine(3, "Enter this PIN when the phone asks:")

                        Text(pin)
                            .font(.system(.title2, design: .monospaced)).bold()
                            .textSelection(.enabled)
                    }
                }

                Text(urlString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("Both devices have to be on the same Wi-Fi network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(server.statusMessage)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 150)
            }

            HStack {
                Text("Air Mouse lives in your menu bar from now on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Helpers

    private func advanceToPairing() {
        waitTimer?.invalidate()
        waitTimer = nil
        startServerIfNeeded()
        step = .pairing
    }

    private func startWaitTimer() {
        guard waitTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            Task { @MainActor in
                if !permissions.isTrusted { showRestartHint = true }
            }
        }
        waitTimer = timer
    }

    private func startServerIfNeeded() {
        if !server.isRunning {
            server.start()
        }
    }

    private func stepLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
