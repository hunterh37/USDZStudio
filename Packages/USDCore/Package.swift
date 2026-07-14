// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "USDCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USDCore", targets: ["USDCore"])
    ],
    targets: [
        .target(name: "USDCore", path: "Sources/USDCore"),
        .testTarget(name: "USDCoreTests", dependencies: ["USDCore"], path: "Tests/USDCoreTests"),
    ]
)
