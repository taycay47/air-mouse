import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import AirMouseCore

// Phase 3 (early) of the Swift port: TLS + WebSocket + static HTTP on one port,
// plus auth/pairing — see the project plan and docs/adr/0002 for the design
// rationale. Reuses AirMouseCore's InjectionSession (phase 1) for the actual
// CoreGraphics injection once a connection is authenticated.
//
// TLS uses swift-nio's NIOSSL, loading the openssl-generated PEM cert/key
// directly (like Python's ssl.SSLContext.load_cert_chain) — no Keychain/SecIdentity
// involved, after that approach (via Network framework) turned out to require a
// user-facing "wants to sign using key" Keychain prompt. See the project plan.
//
// This runs in-process inside AirMouseBar (see ServerManager.swift) rather than
// as a separate spawned binary — the earlier spawned-child-process shape
// (mirroring mouse_controller.py's) reintroduced exactly the problem ADR-0002
// set out to fix: Accessibility ends up granted to the wrong, unstable binary.
// One process, one grant, matches ADR-0002's actual goal.
public final class AirMouseServerRunner {
    public struct Info {
        public let pin: String
        public let url: String
    }

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init() {}

    /// Blocks the calling thread only for the brief initial bind — call this
    /// off the main thread (see ServerManager.swift) so it doesn't stall a GUI.
    /// The server itself then runs on its own event loop thread.
    public func start(port: Int, webRoot: URL, appSupportDir: URL) throws -> Info {
        let (certURL, keyURL) = try ensureCertAndKey(dir: appSupportDir)
        let certificates = try NIOSSLCertificate.fromPEMFile(certURL.path)
        let privateKey = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
        let tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        let auth = AuthState(appSupportDir: appSupportDir)

        let wsUpgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(WebSocketHandler(auth: auth))
            }
        )

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // configureHTTPServerPipeline only removes the HTTP handlers *it* installs on a
                // successful upgrade — a handler appended afterward (httpHandler, for serving
                // static files) is left dangling in the pipeline unless removed explicitly here,
                // where it would otherwise receive post-upgrade WebSocket frames and crash.
                let httpHandler = HTTPHandler(webRoot: webRoot)
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [wsUpgrader],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext)).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(
                        withServerUpgrade: upgradeConfig,
                        withErrorHandling: true
                    )
                }.flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Without this, Nagle's algorithm can hold small outbound frames (like
            // focus_keyboard, a few bytes) for tens-to-hundreds of ms waiting to
            // batch them — enough to miss the phone's touch window that focus_keyboard
            // depends on (see ADR-0004/web/index.html's keyboardPending mechanism).
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        channel = try bootstrap.bind(host: "::", port: port).wait()

        var hostname = ProcessInfo.processInfo.hostName
        if !hostname.hasSuffix(".local") { hostname += ".local" }
        return Info(pin: auth.pin, url: "https://\(hostname):\(port)")
    }

    public func stop() {
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        channel = nil
        group = nil
    }
}
