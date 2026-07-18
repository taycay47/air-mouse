// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirMouseBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AirMouseBar",
            path: "Sources/AirMouseBar"
        )
    ]
)
