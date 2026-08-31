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

    init(auth: AuthState) {
        self.auth = auth
    }

    // Any connection ending releases the shared drag-flag state, exactly like
    // mouse_controller.py's handle_ws_client `finally` block — this runs
    // regardless of which connection actually set the flags (see AirMouseCore).
    func channelInactive(context: ChannelHandlerContext) {
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
            switch auth.attempt(token: token, pin: pin) {
            case .ok(let issuedToken):
                authenticated = true
                sendJSON(["type": "auth_ok", "token": issuedToken], context: context)
            case .failRateLimited:
                sendJSON(["type": "auth_fail", "reason": "rate_limited"], context: context)
            case .failInvalid:
                sendJSON(["type": "auth_fail"], context: context)
            }
            return
        }

        let trigger = session.handle(packet)
        if case .checkFocus(let delaySeconds, let clipboardChanged, let announceFocus) = trigger {
            scheduleFocusCheck(
                delaySeconds: delaySeconds, clipboardChanged: clipboardChanged,
                announceFocus: announceFocus, context: context
            )
        }
    }

    // Ported from mouse_controller.py's _check_text_focus. The actual AX/clipboard
    // read happens off the event loop (see AirMouseCore.performFocusAndClipboardCheck) —
    // this only schedules the delay and sends the resulting state messages, never
    // gating or delaying any real control message (docs/adr/0004).
    private func scheduleFocusCheck(delaySeconds: Double, clipboardChanged: Bool, announceFocus: Bool, context: ChannelHandlerContext) {
        let channel = context.channel
        channel.eventLoop.scheduleTask(in: .milliseconds(Int64(delaySeconds * 1000))) {
            performFocusAndClipboardCheck(clipboardChanged: clipboardChanged) { focus, hasClipboard in
                sendJSONFrame(["type": "focus_state", "focused": focus.isTextField], channel: channel)
                // focus_keyboard consumes the phone's next touch, so it must only be
                // sent on a genuine tap — never drag-release or double-click (ADR-0004).
                if focus.isTextField && announceFocus {
                    sendJSONFrame(["type": "focus_keyboard"], channel: channel)
                }
                sendJSONFrame(["type": "context", "hasSelection": focus.hasSelection, "hasClipboard": hasClipboard], channel: channel)
            }
        }
    }

    private func sendJSON(_ obj: [String: Any], context: ChannelHandlerContext) {
        sendJSONFrame(obj, channel: context.channel)
    }
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
