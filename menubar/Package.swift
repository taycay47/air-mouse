// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirMouseBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AirMouseBar",
            dependencies: [
                "AirMouseCore",
                "AirMouseServerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AirMouseBar"
        ),
        .target(
            name: "AirMouseCore",
            path: "Sources/AirMouseCore"
        ),
        .target(
            name: "AirMouseServerCore",
            dependencies: [
                "AirMouseCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/AirMouseServerCore"
        ),
        .executableTarget(
            name: "AirMouseInjector",
            dependencies: ["AirMouseCore"],
            path: "Sources/AirMouseInjector"
        ),
        .executableTarget(
            name: "AirMouseServer",
            dependencies: ["AirMouseCore", "AirMouseServerCore"],
            path: "Sources/AirMouseServer"
        )
    ]
)
