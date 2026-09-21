// swift-tools-version:5.9
import PackageDescription

// Shared, platform-agnostic core used by the Mac server and the iOS client
// (docs/ROADMAP.md step 5). Nothing here imports AppKit, UIKit or NIO, so it
// builds and tests on macOS without a simulator — which is what lets the
// gesture logic be verified without an iPhone in the loop.
let package = Package(
    name: "AirMouseKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AirMouseProtocol", targets: ["AirMouseProtocol"]),
        .library(name: "AirMouseGestures", targets: ["AirMouseGestures"]),
    ],
    targets: [
        .target(name: "AirMouseProtocol"),
        .target(name: "AirMouseGestures", dependencies: ["AirMouseProtocol"]),
        .testTarget(name: "AirMouseProtocolTests", dependencies: ["AirMouseProtocol"]),
        .testTarget(name: "AirMouseGesturesTests", dependencies: ["AirMouseGestures"]),
    ]
)
