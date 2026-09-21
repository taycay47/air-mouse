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

    init(auth: AuthState) {
        self.auth = auth
    }

    // Any connection ending releases the shared drag-flag state, exactly like
    // mouse_controller.py's handle_ws_client `finally` block — this runs
    // regardless of which connection actually set the flags (see AirMouseCore).
    func channelInactive(context: ChannelHandlerContext) {
        permissionTimer?.cancel()
        permissionTimer = nil
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
                sendJSON(["type": "auth_ok", "token": issuedToken], context: context)
                startPermissionReporting(context: context)
            case .failRateLimited:
                logError("auth rate limited")
                sendJSON(["type": "auth_fail", "reason": "rate_limited"], context: context)
            case .failInvalid:
                logError("auth invalid")
                sendJSON(["type": "auth_fail"], context: context)
            }
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
                announceFocus: announceFocus, context: context, generation: checkGeneration
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
    private func scheduleFocusCheck(delaySeconds: Double, clipboardChanged: Bool, announceFocus: Bool, context: ChannelHandlerContext, generation: UInt64) {
        let channel = context.channel
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
    private func startPermissionReporting(context: ChannelHandlerContext) {
        let channel = context.channel
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

    private func sendJSON(_ obj: [String: Any], context: ChannelHandlerContext) {
        sendJSONFrame(obj, channel: context.channel)
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
