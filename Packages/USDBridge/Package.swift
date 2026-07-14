// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "USDBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "USDBridge", targets: ["USDBridge"])
    ],
    dependencies: [
        .package(path: "../USDCore")
    ],
    targets: [
        .target(name: "USDBridge", dependencies: ["USDCore"], path: "Sources/USDBridge"),
        .testTarget(
            name: "USDBridgeTests",
            dependencies: ["USDBridge"],
            path: "Tests/USDBridgeTests",
            resources: [.copy("Fixtures")]),
    ]
)
