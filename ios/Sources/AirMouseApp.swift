import SwiftUI
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
    @StateObject private var discovery = Discovery()
    @StateObject private var connection = Connection()
    @State private var haptics = Haptics()
    @State private var pin = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch connection.state {
            case .idle, .connecting, .failed:
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
                    // is enough to connect — no separate resolve step.
                    connection.connect(to: mac,
                                       host: mac.host ?? "\(mac.name).local",
                                       port: mac.port ?? 8443)
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

            if case .failed(let message) = connection.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
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
            TrackpadView(send: { connection.send($0) }, haptics: haptics)
                .ignoresSafeArea()

            if !connection.accessibilityGranted {
                Text("Air Mouse can't control your Mac — Accessibility permission is off.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.85))
            }
        }
    }
}
