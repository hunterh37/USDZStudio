// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EditingKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditingKit", targets: ["EditingKit"])
    ],
    dependencies: [
        .package(path: "../USDCore"),
        .package(path: "../ValidationKit")
    ],
    targets: [
        .target(name: "EditingKit", dependencies: ["USDCore", "ValidationKit"], path: "Sources/EditingKit"),
        .testTarget(name: "EditingKitTests", dependencies: ["EditingKit"], path: "Tests/EditingKitTests"),
    ]
)
