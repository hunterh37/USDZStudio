// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EditingKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditingKit", targets: ["EditingKit"])
    ],
    dependencies: [
        .package(path: "../USDCore")
    ],
    targets: [
        .target(name: "EditingKit", dependencies: ["USDCore"], path: "Sources/EditingKit"),
        .testTarget(name: "EditingKitTests", dependencies: ["EditingKit"], path: "Tests/EditingKitTests"),
    ]
)
