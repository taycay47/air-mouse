import Foundation
import AirMouseCore

// Phase 1 of the Swift port (see docs/adr/0002-port-input-injection-from-python-to-swift.md
// and docs/ROADMAP.md step 1): a standalone CLI that reads newline-delimited JSON
// messages from stdin and performs the corresponding CoreGraphics input injection.
// All the actual device-action logic lives in AirMouseCore, shared with AirMouseServer.
//
// Framing note: docs/PROTOCOL.md describes the WebSocket wire format, not stdin framing.
// One JSON object per line is this port's own choice for driving/testing this CLI
// standalone, ahead of the WebSocket layer.

signal(SIGINT) { _ in
    releaseHeldButtons()
    exit(0)
}
signal(SIGTERM) { _ in
    releaseHeldButtons()
    exit(0)
}

let session = InjectionSession()

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let packet = obj as? [String: Any]
    else {
        continue // malformed line — ignored, not fatal (protocol invariant 2)
    }
    session.handle(packet)
}

// EOF on stdin (pipe closed / process ending normally) — same cleanup as a signal.
releaseHeldButtons()
