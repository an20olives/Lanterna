// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LanternaKit",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LanternaKit", targets: ["LanternaKit"]),
    ],
    targets: [
        .target(name: "LanternaKit"),
        .testTarget(name: "LanternaKitTests", dependencies: ["LanternaKit"], resources: [.copy("Fixtures")]),
    ]
)
