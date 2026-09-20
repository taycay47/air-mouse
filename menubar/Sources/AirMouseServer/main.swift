import Foundation
import AirMouseCore
import AirMouseServerCore

// Standalone dev/test CLI wrapping AirMouseServerCore.AirMouseServerRunner — useful for
// manual testing and debugging without launching the full AirMouseBar app. The actual
// shipped app runs the server in-process instead (see AirMouseBar/ServerManager.swift)
// so Accessibility is granted to one stable binary, not this one.

// stdout is fully buffered (not line-buffered) when not attached to a TTY.
setvbuf(stdout, nil, _IOLBF, 0)

let port: Int = {
    if CommandLine.arguments.count > 1, let p = Int(CommandLine.arguments[1]) {
        return p
    }
    return 8443
}()

// Repo root, resolved relative to this source file's own location at compile time.
let webRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // main.swift -> AirMouseServer/
    .deletingLastPathComponent() // AirMouseServer/ -> Sources/
    .deletingLastPathComponent() // Sources/ -> menubar/
    .deletingLastPathComponent() // menubar/ -> repo root
    .appendingPathComponent("web", isDirectory: true)

signal(SIGINT) { _ in
    releaseHeldButtons()
    exit(0)
}
signal(SIGTERM) { _ in
    releaseHeldButtons()
    exit(0)
}

let runner = AirMouseServerRunner()
do {
    let appSupportDir = try appSupportDirectory()
    let info = try runner.start(port: port, webRoot: webRoot, appSupportDir: appSupportDir)
    print("PAIRING PIN: \(info.pin)")
    print(info.url)
} catch {
    logError("Failed to start listener: \(error)")
    exit(1)
}

// Blocks forever, pumping the main dispatch queue — required (not just
// convenient) because AirMouseCore.performFocusAndClipboardCheck dispatches
// AX reads onto DispatchQueue.main, which needs an actively-serviced main
// thread to receive their cross-process replies (see AirMouseCore/Accessibility.swift).
// AirMouseBar doesn't need this itself since a GUI app already pumps its own
// main run loop continuously.
dispatchMain()
