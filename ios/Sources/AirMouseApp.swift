import SwiftUI
import UIKit
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
    @StateObject private var keyboardInset = KeyboardInset()
    /// Held here rather than inside ActionButton so the touch surface can close
    /// the panel. Tapping the trackpad is how you dismiss it — the alternative
    /// was a panel that stayed open behind every subsequent gesture.
    @State private var actionsOpen = false
    /// Which actions the panel offers. A stored arrangement today, an editable
    /// one later; the views already read it rather than a hardcoded list.
    @StateObject private var actions = ActionSettings()

    private var isOffline: Bool { !connection.isLive }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AmbientGlow(isOffline: isOffline, bottomInset: keyboardInset.height)
            DotGrid(effects: effects, isOffline: isOffline)

            // Present in every state, connected or not. Touching a disconnected
            // surface still ripples — the app stays alive while it works out
            // what is wrong, where a dead rectangle would say the opposite.
            // `send` is harmlessly ignored until there is a socket.
            TrackpadView(send: { connection.send($0) },
                         haptics: haptics,
                         effects: effects,
                         onTouchDown: { actionsOpen = false })
                .ignoresSafeArea()

            overlay
        }
        .onAppear {
            discovery.start()
            // The phone must not dim or lock while this is on screen. It is a
            // trackpad: long stretches of reading with a hand resting on it are
            // the normal case, and they look exactly like idleness to iOS.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            discovery.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: discovery.macs) { macs in autoConnect(macs) }
        // `onChange` alone is not enough: after a failure the Mac list is often
        // unchanged, so nothing fires and the app sits red forever with a Mac
        // it can see and is not dialling. This is the second half of that fix
        // — the first is Discovery reviving its own browser.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            autoConnect(discovery.macs)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                discovery.start()
                connection.reconnectIfNeeded()
                UIApplication.shared.isIdleTimerDisabled = true
            case .background:
                connection.releaseHeldInput()
                UIApplication.shared.isIdleTimerDisabled = false
            default:
                break
            }
        }
    }

    /// Connects without being asked when there is exactly one Mac.
    ///
    /// Choosing from a list of one is not a choice. The picker appears only
    /// when there is genuinely something to pick between.
    ///
    /// `failed` counts as ready to try again, not as a resting place. It used
    /// to be excluded, which quietly threw away the single best signal the app
    /// gets: the Mac's Bonjour service reappearing means the server is *back*,
    /// and it was being ignored in favour of waiting out a retry timer. That is
    /// most of the difference between reconnecting in a second and reconnecting
    /// in a minute.
    private func autoConnect(_ macs: [Discovery.Mac]) {
        guard macs.count == 1 else { return }
        switch connection.state {
        case .idle, .failed:
            connection.connect(to: macs[0])
        case .connecting, .authenticating, .connected, .needsPIN, .identityChanged:
            // Mid-attempt, waiting on the user, or refusing a certificate.
            // Restarting any of those makes things worse.
            break
        }
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
        VStack(spacing: 6) {
            Spacer()
            Text(statusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(offlineText)
            if let statusHint {
                // The only instruction left, and only for the only failure a
                // person can act on from the phone. Quiet enough to ignore
                // until it is the thing you need.
                Text(statusHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(offlineText.opacity(0.55))
            }
            Spacer().frame(height: 80)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.3), value: statusText)
    }

    /// Two words at most.
    ///
    /// The grid is already saying this, in red, pulsing up the screen — the
    /// text only names it. The old version explained the fix in two lines of
    /// prose laid over an animation nobody could then look at.
    private var statusText: String {
        if discovery.failure != nil { return "No local network" }
        switch connection.state {
        case .connecting, .authenticating:
            return "Connecting"
        case .failed:
            return "Out of reach"
        case .idle where !discovery.macs.isEmpty:
            return "Connecting"
        default:
            return "Searching"
        }
    }

    private var statusHint: String? {
        discovery.failure != nil ? "Settings › Air Mouse" : nil
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

            // One column in the bottom-right corner, everything in it the same
            // size and on the same edge. The keyboard's open and close buttons
            // are the same control in the same place — before, one was bottom
            // left and the other bottom right, and they were different sizes,
            // so dismissing the keyboard meant hunting for a button that had
            // moved across the screen.
            VStack(alignment: .trailing, spacing: 10) {
                ContextPills(hasSelection: connection.hasSelection,
                             hasClipboard: connection.hasClipboard,
                             send: { connection.send($0) },
                             haptics: haptics)

                ActionButton(settings: actions,
                             isOpen: $actionsOpen,
                             send: { connection.send($0) },
                             haptics: haptics,
                             onFired: { effects.pulse(.success, at: CACurrentMediaTime()) })

                if showKeyboard {
                    KeyboardBar(text: $typed,
                                macFieldFocused: connection.macFieldFocused,
                                send: { connection.send($0) },
                                haptics: haptics,
                                onDone: { showKeyboard = false })
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        showKeyboard = true
                        haptics.play(.tap)
                    } label: {
                        // Plain `keyboard`, because `keyboard.chevron.compact.up`
                        // is not an SF Symbol — only the `.down` and `.left`
                        // variants exist, so the button was rendering nothing at
                        // all. The chevron belongs to dismissal anyway.
                        Image(systemName: "keyboard")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: ControlMetrics.size,
                                   height: ControlMetrics.size)
                    }
                    .foregroundStyle(.white)
                    .glassSurface(in: Circle())
                    .accessibilityLabel("Keyboard")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showKeyboard)
    }
}
