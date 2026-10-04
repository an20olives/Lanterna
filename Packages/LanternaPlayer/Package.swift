// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LanternaPlayer",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LanternaPlayer", targets: ["LanternaPlayer"]),
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
    ],
    dependencies: [
        // Exact pins. Both are GPL-3.0; see docs/dependencies.md.
        .package(url: "https://github.com/kingslay/KSPlayer.git", exact: "2.3.4"),
        .package(url: "https://github.com/kingslay/FFmpegKit.git", exact: "6.1.4"),
    ],
    targets: [
        // Pure Swift: probe model, routing policy, HLS playlists, fMP4 boxes, WebVTT, tiny HTTP server.
        .target(name: "PlayerCore"),
        // Engine A: on-device remux to fMP4 HLS served from 127.0.0.1.
        .target(
            name: "EngineA",
            dependencies: [
                "PlayerCore",
                .product(name: "FFmpegKit", package: "FFmpegKit"),
            ]
        ),
        // Engine C: KSPlayer MEPlayer (FFmpeg renderer).
        .target(
            name: "EngineC",
            dependencies: [
                "PlayerCore",
                .product(name: "KSPlayer", package: "KSPlayer"),
            ]
        ),
        .target(
            name: "LanternaPlayer",
            dependencies: ["PlayerCore", "EngineA", "EngineC"]
        ),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"]),
        .testTarget(name: "EngineATests", dependencies: ["EngineA", "PlayerCore"]),
    ]
)
