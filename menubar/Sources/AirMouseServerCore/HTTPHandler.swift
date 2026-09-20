import Foundation
import NIOCore
import NIOHTTP1

// Serves static files for any request that didn't get upgraded to WebSocket by
// NIOWebSocketServerUpgrader (see main.swift). Ported from mouse_controller.py's
// process_request static-file branch.
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let webRoot: URL
    private var requestHead: HTTPRequestHead?

    init(webRoot: URL) {
        self.webRoot = webRoot
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else { return }
            let response = serveStaticFile(requestPath: head.uri, webRoot: webRoot)

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Content-Length", value: String(response.body.count))
            headers.add(name: "Connection", value: "close")
            headers.add(name: "Cache-Control", value: "no-store, no-cache, must-revalidate, max-age=0")
            headers.add(name: "Pragma", value: "no-cache")
            headers.add(name: "Expires", value: "0")

            let status = HTTPResponseStatus.custom(code: UInt(response.statusCode), reasonPhrase: response.reasonPhrase)
            let responseHead = HTTPResponseHead(version: head.version, status: status, headers: headers)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}
