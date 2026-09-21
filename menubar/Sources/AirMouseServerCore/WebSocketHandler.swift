import Foundation
import NIOCore
import NIOWebSocket
import AirMouseCore

// One instance per upgraded WebSocket connection (installed by
// NIOWebSocketServerUpgrader's upgradePipelineHandler in main.swift). Owns one
// InjectionSession (per-connection state) and gates control messages behind
// AuthState — mirrors mouse_controller.py's handle_ws_client.
final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let auth: AuthState
    private let session = InjectionSession()
    private var authenticated = false
    private var closeSent = false
    /// Bumped per focus check so stale in-flight checks can be discarded rather
    /// than emitting state that has since been superseded. Event-loop confined.
    private var checkGeneration: UInt64 = 0
    /// Last Accessibility state sent to this client, so only changes go on the
    /// wire. nil until the first report.
    private var lastReportedPermission: Bool?
    private var permissionTimer: RepeatedTask?
    /// The DTLS/UDP channel offered to this client, if it could be opened.
    /// Per-session, so its key dies with the session.
    private var fast: FastChannel?

    init(auth: AuthState) {
        self.auth = auth
    }

    // Any connection ending releases the shared drag-flag state, exactly like
    // mouse_controller.py's handle_ws_client `finally` block — this runs
    // regardless of which connection actually set the flags (see AirMouseCore).
    func channelInactive(context: ChannelHandlerContext) {
        permissionTimer?.cancel()
        permissionTimer = nil
        fast?.stop()
        fast = nil
        releaseHeldButtons()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var buffer = frame.unmaskedData
            guard let bytes = buffer.readBytes(length: buffer.readableBytes),
                  let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
            else { return }
            handlePacket(obj, context: context)
        case .connectionClose:
            handleClose(context: context, frame: frame)
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .binary, .continuation, .pong:
            break // not used by this protocol
        default:
            break
        }
    }

    private func handleClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        guard !closeSent else {
            context.close(promise: nil)
            return
        }
        closeSent = true
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
        context.writeAndFlush(wrapOutboundOut(closeFrame)).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func handlePacket(_ packet: [String: Any], context: ChannelHandlerContext) {
        let channel = context.channel
        handlePacket(packet, channel: channel, reply: { sendJSONFrame($0, channel: channel) })
    }

    /// `reply` answers on whichever channel the packet arrived by. A `ping` that
    /// came in over UDP must be answered over UDP or its round-trip time
    /// measures the wrong thing entirely.
    private func handlePacket(_ packet: [String: Any], channel: Channel,
                              reply: @escaping ([String: Any]) -> Void) {
        guard let type = packet["type"] as? String else { return } // unknown/malformed — ignored

        // Every control message before auth_ok must be dropped (docs/PROTOCOL.md).
        if !authenticated {
            guard type == "auth" else { return }
            let token = packet["token"] as? String
            let pin = packet["pin"] as? String
            logError("auth attempt: token=\(token != nil), pin=\(pin != nil)")
            switch auth.attempt(token: token, pin: pin) {
            case .ok(let issuedToken):
                logError("auth ok")
                authenticated = true
                // A newly authenticated connection means any button still held from a
                // previous one is stale — the gesture that pressed it is definitively
                // over. Releasing here recovers automatically from a client that
                // dropped mid-drag without sending its 'up' (ADR-0006).
                releaseHeldButtons()
                reply(["type": "auth_ok", "token": issuedToken])
                startPermissionReporting(channel: channel)
                offerFastChannel(channel: channel)
            case .failRateLimited:
                logError("auth rate limited")
                reply(["type": "auth_fail", "reason": "rate_limited"])
            case .failInvalid:
                logError("auth invalid")
                reply(["type": "auth_fail"])
            }
            return
        }

        // Answered before anything else touches it, and never handed to the
        // injector: a probe that queued behind a focus check would measure the
        // server's own scheduling rather than the network.
        if type == "ping" {
            reply(["type": "pong", "id": packet["id"] ?? 0])
            return
        }

        let trigger = session.handle(packet)
        if case .checkFocus(let delaySeconds, let clipboardChanged, let announceFocus) = trigger {
            // Only the newest check is still meaningful: focus/selection have moved on.
            // Without this, checks queue up behind each other on the serial AX queue and
            // land late — arming focus_keyboard long after the tap, so the keyboard opens
            // on some unrelated later touch (e.g. while moving the cursor).
            checkGeneration &+= 1
            scheduleFocusCheck(
                delaySeconds: delaySeconds, clipboardChanged: clipboardChanged,
                announceFocus: announceFocus, channel: channel, generation: checkGeneration
            )
        }
    }

    /// True only if no newer focus check has been requested since this one.
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == checkGeneration
    }

    // Ported from mouse_controller.py's _check_text_focus. The actual AX/clipboard
    // read happens off the event loop (see AirMouseCore.performFocusAndClipboardCheck) —
    // this only schedules the delay and sends the resulting state messages, never
    // gating or delaying any real control message (docs/adr/0004).
    private func scheduleFocusCheck(delaySeconds: Double, clipboardChanged: Bool, announceFocus: Bool, channel: Channel, generation: UInt64) {
        let eventLoop = channel.eventLoop

        eventLoop.scheduleTask(in: .milliseconds(Int64(delaySeconds * 1000))) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            performFocusAndClipboardCheck(clipboardChanged: clipboardChanged) { focus, hasClipboard in
                // Back to the event loop so the generation check isn't racing.
                eventLoop.execute { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    emitFocusMessages(focus: focus, hasClipboard: hasClipboard, announceFocus: announceFocus, channel: channel)
                }
            }
        }
    }


    /// Reports the Accessibility grant, then watches it for the life of the
    /// connection.
    ///
    /// Polled rather than pushed because macOS provides no notification when a
    /// grant is revoked, and revocation is invisible from the client's side —
    /// the socket stays up and every message is still accepted. 2s is well
    /// inside the time it takes a user to switch back from System Settings and
    /// wonder why nothing works.
    private func startPermissionReporting(channel: Channel) {
        reportPermissionIfChanged(channel: channel)
        permissionTimer?.cancel()
        permissionTimer = channel.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(2), delay: .seconds(2)
        ) { [weak self] _ in
            self?.reportPermissionIfChanged(channel: channel)
        }
    }

    private func reportPermissionIfChanged(channel: Channel) {
        let granted = hasAccessibilityPermission()
        guard granted != lastReportedPermission else { return }
        lastReportedPermission = granted
        sendJSONFrame(["type": "permission", "accessibility": granted], channel: channel)
    }

    /// Opens the DTLS/UDP channel and tells the client how to reach it.
    ///
    /// Strictly an upgrade. If the listener cannot be created, no offer is sent
    /// and nothing else changes — the client is already working over the channel
    /// this message is travelling on.
    private func offerFastChannel(channel: Channel) {
        fast?.stop()
        let eventLoop = channel.eventLoop
        let channelBox = channel
        self.fast = FastChannel(handler: { [weak self] packet, reply in
            // Onto the event loop, because InjectionSession is not thread-safe
            // and — more importantly — because input arriving on two channels
            // must still be applied in one order. A mouse-down racing a movement
            // is a drag that starts in the wrong place.
            eventLoop.execute {
                self?.handlePacket(packet, channel: channelBox, reply: reply)
            }
        }, onReady: { fast in
            logError("[Fast] DTLS/UDP on port \(fast.port) as \(fast.serviceName)")
            sendJSONFrame([
                "type": "fast_channel",
                "port": fast.port,
                "key": fast.key,
                "identity": fast.identity,
                "service": fast.serviceName,
            ], channel: channelBox)
        })
        if fast == nil {
            logError("[Fast] listener unavailable — staying on TCP")
        }
    }
}

// Emits the three advisory state messages in mouse_controller.py's order:
// focus_state, then focus_keyboard (tap only), then context.
private func emitFocusMessages(focus: FocusInfo, hasClipboard: Bool, announceFocus: Bool, channel: Channel) {
    sendJSONFrame(["type": "focus_state", "focused": focus.isTextField], channel: channel)
    // Advisory only: it reports that a text field took focus, and the client
    // decides what to do with that. Sent on a genuine tap alone — on a
    // drag-release or double-click the hint is meaningless (ADR-0004, ADR-0008).
    if focus.isTextField && announceFocus {
        sendJSONFrame(["type": "focus_keyboard"], channel: channel)
    }
    sendJSONFrame(["type": "context", "hasSelection": focus.hasSelection, "hasClipboard": hasClipboard], channel: channel)
}

// Free function so it's safely callable from the background queue that
// performFocusAndClipboardCheck's completion runs on — NIOCore's Channel is
// documented safe to use from any thread, unlike ChannelHandlerContext.
private func sendJSONFrame(_ obj: [String: Any], channel: Channel) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
    channel.writeAndFlush(frame, promise: nil)
}
