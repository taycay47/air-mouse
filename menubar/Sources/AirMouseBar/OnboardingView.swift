import SwiftUI
import AppKit

/// First-run flow: get Accessibility, then show the PIN.
///
/// The permission step advances by itself as soon as the grant lands
/// (docs/ROADMAP.md step 3). Everything that only matters when something goes
/// wrong — restarting, adding the app by hand, pairing from a browser — stays
/// out of sight until it is needed.
struct OnboardingView: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var permissions: PermissionsMonitor
    var onFinish: () -> Void

    private enum Step {
        case access, pair
    }

    @State private var step: Step = .access
    @State private var requested = false
    /// Shown only after waiting a while, so the normal path stays uncluttered.
    @State private var showRestartHint = false
    @State private var waitTimer: Timer?
    @State private var showBrowserPairing = false

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)

            Group {
                switch step {
                case .access: access
                case .pair: pair
                }
            }
            .transition(.opacity)

            StepDots(count: 2, current: step == .access ? 0 : 1)
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 380)
        .animation(.easeOut(duration: 0.2), value: step)
        .animation(.easeOut(duration: 0.2), value: showRestartHint)
        .animation(.easeOut(duration: 0.2), value: showBrowserPairing)
        .onAppear {
            permissions.startPolling()
            // Coming back from a restart that was needed to pick up the grant:
            // don't make the user walk the whole flow again.
            if permissions.isTrusted { advanceToPairing() }
        }
        .onDisappear {
            waitTimer?.invalidate()
            waitTimer = nil
        }
        .onChange(of: permissions.isTrusted) { trusted in
            if trusted && step == .access { advanceToPairing() }
        }
    }

    // MARK: - Steps

    private var access: some View {
        VStack(spacing: 18) {
            heading("Allow control",
                    "Turn on Air Mouse in the list macOS opens.")

            if requested {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting…").foregroundStyle(.secondary)
                }
                .frame(height: 32)
            } else {
                Button {
                    // Deliberately does not also open System Settings: doing both in
                    // one action suppresses the macOS dialog, and that dialog is what
                    // registers the app so it appears in the list at all.
                    permissions.requestAccess()
                    requested = true
                    startWaitTimer()
                } label: {
                    Text("Allow").frame(minWidth: 120)
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            if showRestartHint {
                // macOS sometimes won't hand a new grant to a running process;
                // and an app that never asked isn't listed at all.
                HStack(spacing: 16) {
                    Button("Already on? Restart") { permissions.relaunch() }
                    Button("Not listed?") {
                        permissions.openSystemSettings()
                        permissions.revealInFinder()
                    }
                    .help("Drag Air Mouse into the Accessibility list")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    private var pair: some View {
        VStack(spacing: 18) {
            heading("Pair your phone",
                    "Open Air Mouse on your iPhone and enter this PIN.")

            if let pin = server.pin {
                PinCard(pin: pin, size: 32)

                if showBrowserPairing, let url = server.url {
                    VStack(spacing: 6) {
                        BrowserPairing(url: url)
                        Text("Safari warns about the certificate — that's expected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("No app? Use the browser") { showBrowserPairing = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 80)
            }

            Button {
                onFinish()
            } label: {
                Text("Done").frame(minWidth: 120)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func advanceToPairing() {
        waitTimer?.invalidate()
        waitTimer = nil
        if !server.isRunning { server.start() }
        step = .pair
    }

    private func startWaitTimer() {
        guard waitTimer == nil else { return }
        waitTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { _ in
            Task { @MainActor in
                if !permissions.isTrusted { showRestartHint = true }
            }
        }
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
