import SwiftUI
import QuartzCore
import AirMouseProtocol

@main
struct AirMouseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

/// One screen, always.
///
/// The grid is the interface. It is never swapped out for a picker, a spinner
/// or an error page — it stays, and its colour and movement carry the state:
/// white and calm when connected, red and pulsing from its centre when not.
/// Everything else is a thin layer on top of it.
///
/// This replaces a conventional app built *around* the grid — a title screen, a
/// device list, a full-page failure — which buried the one thing the app is for
/// behind furniture nobody needed.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = Discovery()
    @StateObject private var connection = Connection()
    @State private var haptics = Haptics()
    @State private var pin = ""
    @State private var typed = ""
    @State private var showKeyboard = false
    @State private var effects = SurfaceEffects()

    private var isOffline: Bool { !connection.isLive }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AmbientGlow(isOffline: isOffline)
            DotGrid(effects: effects, isOffline: isOffline)

            // Present in every state, connected or not. Touching a disconnected
            // surface still ripples — the app stays alive while it works out
            // what is wrong, where a dead rectangle would say the opposite.
            // `send` is harmlessly ignored until there is a socket.
            TrackpadView(send: { connection.send($0) },
                         haptics: haptics,
                         effects: effects)
                .ignoresSafeArea()

            overlay
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: discovery.macs) { macs in autoConnect(macs) }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                discovery.start()
                connection.reconnectIfNeeded()
            case .background:
                connection.releaseHeldInput()
            default:
                break
            }
        }
    }

    /// Connects without being asked when there is exactly one Mac.
    ///
    /// Choosing from a list of one is not a choice. The picker now appears only
    /// when there is genuinely something to pick between.
    private func autoConnect(_ macs: [Discovery.Mac]) {
        guard case .idle = connection.state, macs.count == 1 else { return }
        connection.connect(to: macs[0])
    }

    // MARK: - Layers

    @ViewBuilder
    private var overlay: some View {
        switch connection.state {
        case .connected:
            controls
        case .needsPIN(let message):
            pinEntry(message: message)
        case .identityChanged:
            identityChanged
        case .idle, .connecting, .authenticating, .failed:
            if discovery.macs.count > 1 {
                picker
            } else {
                status
            }
        }
    }

    // MARK: - Status
    //
    // One line, low and quiet. The grid already says "something is wrong", in
    // red and pulsing from its centre; this only names it. Anything longer is a
    // wall of text over an animation the user is meant to be reading.

    private var status: some View {
        VStack {
            Spacer()
            Text(statusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(offlineText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer().frame(height: 80)
        }
        .animation(.easeInOut(duration: 0.3), value: statusText)
    }

    private var statusText: String {
        // The only failure worth instructions: nothing else here can be fixed
        // from the phone.
        if discovery.failure != nil {
            return "Turn on Local Network access\nin Settings › Air Mouse"
        }
        switch connection.state {
        case .connecting, .authenticating:
            return "Connecting"
        case .failed:
            return "Can't reach your Mac"
        case .idle where !discovery.macs.isEmpty:
            return "Connecting"
        default:
            return "Looking for your Mac"
        }
    }

    /// Salmon rather than white, matching the web client's offline palette: the
    /// text belongs to the red state rather than sitting on top of it.
    private var offlineText: Color {
        Color(red: 1, green: 138 / 255, blue: 128 / 255).opacity(0.92)
    }

    // MARK: - Choosing, only when there is a choice

    private var picker: some View {
        VStack(spacing: 10) {
            Spacer()
            ForEach(discovery.macs) { mac in
                Button { connection.connect(to: mac) } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(mac.name)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 14))
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            Spacer().frame(height: 70)
        }
    }

    // MARK: - Pairing

    private func pinEntry(message: String?) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text(message ?? "Enter the PIN from your Mac")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(message == nil ? Color.white.opacity(0.7) : offlineText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            TextField("000000", text: $pin)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 180)
                .padding(.vertical, 12)
                .glassSurface(in: Capsule(), interactive: false)
                .onChange(of: pin) { value in
                    // Submits itself on the sixth digit. A Pair button is one
                    // tap of ceremony after the only input that matters.
                    let digits = value.filter(\.isNumber)
                    if digits.count == 6 {
                        connection.submit(pin: digits)
                        haptics.play(.tap)
                        pin = ""
                    }
                }
            Spacer().frame(height: 90)
        }
    }

    // MARK: - Pinning refused

    private var identityChanged: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(offlineText)
            Text("This Mac's certificate changed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("It isn't the one this phone paired with. Expected if the Mac was renamed — otherwise worth a second look.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Pair again") { connection.acceptNewIdentity() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule())
            Spacer().frame(height: 80)
        }
    }

    // MARK: - Connected

    private var controls: some View {
        VStack(spacing: 0) {
            if !connection.accessibilityGranted {
                Text("Accessibility is off — Air Mouse can't control your Mac")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(offlineText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

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
