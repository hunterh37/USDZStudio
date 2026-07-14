// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ViewportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ViewportKit", targets: ["ViewportKit"])
    ],
    dependencies: [
        .package(path: "../USDCore")
    ],
    targets: [
        .target(name: "ViewportKit", dependencies: ["USDCore"], path: "Sources/ViewportKit"),
        .testTarget(name: "ViewportKitTests", dependencies: ["ViewportKit"], path: "Tests/ViewportKitTests"),
    ]
)
