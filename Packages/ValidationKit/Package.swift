// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ValidationKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ValidationKit", targets: ["ValidationKit"])
    ],
    dependencies: [
        .package(path: "../USDCore")
    ],
    targets: [
        .target(name: "ValidationKit", dependencies: ["USDCore"], path: "Sources/ValidationKit"),
        .testTarget(name: "ValidationKitTests", dependencies: ["ValidationKit"], path: "Tests/ValidationKitTests"),
    ]
)
