import SwiftUI
import QuartzCore
import AirMouseProtocol

@main
struct AirMouseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = Discovery()
    @StateObject private var connection = Connection()
    @State private var haptics = Haptics()
    @State private var pin = ""
    @State private var typed = ""
    @State private var showKeyboard = false
    @State private var effects = SurfaceEffects()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch connection.state {
            case .failed(let message):
                // Its own screen, not a line inside the picker. Rendered there
                // it was replaced the moment a Bonjour result changed, which
                // happens constantly — the message flashed for an instant and
                // vanished before it could be read.
                failure(message)
            case .idle, .connecting:
                picker
            case .needsPIN(let message):
                pinEntry(message: message)
            case .identityChanged:
                identityChanged
            case .authenticating:
                ProgressView().tint(.white)
            case .connected:
                trackpad
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // Coming back from the phone locking or the app being switched
                // away from. The socket is gone; pick the same Mac up again
                // rather than making the user choose it from a list for an
                // interruption they did not cause.
                discovery.start()
                connection.reconnectIfNeeded()
            case .background:
                // Anything held must be released before the app stops running,
                // or the Mac is left dragging (ADR-0006).
                connection.releaseHeldInput()
            default:
                break
            }
        }
    }

    // MARK: - Picking a Mac

    private var picker: some View {
        VStack(spacing: 20) {
            Text("Air Mouse")
                .font(.largeTitle.bold())

            if let failure = discovery.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else if discovery.macs.isEmpty {
                ProgressView().tint(.white)
                Text("Looking for your Mac…")
                    .foregroundStyle(.secondary)
                Text("Both devices have to be on the same Wi-Fi.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            ForEach(discovery.macs) { mac in
                Button {
                    // host and port ride in the TXT record so a browse result
                    // is enough to connect — no separate resolve step. There is
                    // deliberately no fallback to the instance name: that is a
                    // display name ("MacBook Pro von Robert (2)"), not a
                    // hostname, and spaces and parentheses make it unusable in a
                    // URL. Guessing produced a confusing "bad address" instead
                    // of naming the real problem.
                    connection.connect(to: mac)
                } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(mac.name)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
            }

        }
    }

    // MARK: - Failure

    private func failure(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Couldn't connect")
                .font(.title3.bold())
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 28)
            Button("Back") { connection.reset() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Pairing

    private func pinEntry(message: String?) -> some View {
        VStack(spacing: 16) {
            Text("Enter the PIN")
                .font(.title2.bold())
            Text("Shown in the Air Mouse window on your Mac")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("000000", text: $pin)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(.title, design: .monospaced))
                .padding()
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 48)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("Pair") {
                connection.submit(pin: pin)
                pin = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(pin.count != 6)
        }
    }

    // MARK: - Pinning refused

    private var identityChanged: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("This Mac's identity changed")
                .font(.title3.bold())
            Text("""
                The certificate is not the one this phone paired with. That \
                happens legitimately when the Mac regenerates it — after a \
                rename, a network change, or a year passing — but it is also \
                what an impersonation would look like.

                Only continue if you recognise the change.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Pair again", role: .destructive) { connection.acceptNewIdentity() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Connected

    private var trackpad: some View {
        ZStack(alignment: .top) {
            // The grid sits behind the touch surface and takes no touches of
            // its own — it is a status indicator, not a control. Its red tint
            // *is* the disconnected state, which is why there is no status
            // light anywhere in this interface.
            DotGrid(effects: effects, isOffline: !connection.isLive)

            TrackpadView(send: { connection.send($0) },
                         haptics: haptics,
                         effects: effects)
                .ignoresSafeArea()

            if !connection.accessibilityGranted {
                Text("Air Mouse can't control your Mac — Accessibility permission is off.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.85))
            }

            VStack {
                Spacer()
                ContextPills(hasSelection: connection.hasSelection,
                             hasClipboard: connection.hasClipboard,
                             send: { connection.send($0) },
                             haptics: haptics)

                if showKeyboard {
                    KeyboardBar(text: $typed,
                                macFieldFocused: connection.macFieldFocused,
                                send: { connection.send($0) },
                                haptics: haptics,
                                onDone: { showKeyboard = false })
                        .padding(.top, 10)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            showKeyboard = true
                            haptics.play(.tap)
                        } label: {
                            Image(systemName: "keyboard")
                                .font(.system(size: 18))
                                .padding(12)
                                .glassSurface(in: Circle())
                        }
                        .foregroundStyle(.white)

                        ShortcutBar(send: { connection.send($0) },
                                    haptics: haptics,
                                    onFired: { effects.pulse(.success, at: CACurrentMediaTime()) })
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.bottom, 14)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showKeyboard)
        }
    }
}
