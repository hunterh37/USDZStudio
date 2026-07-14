// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ConversionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConversionKit", targets: ["ConversionKit"])
    ],
    dependencies: [
        .package(path: "../USDCore")
    ],
    targets: [
        .target(name: "ConversionKit", dependencies: ["USDCore"], path: "Sources/ConversionKit"),
        .testTarget(name: "ConversionKitTests", dependencies: ["ConversionKit"], path: "Tests/ConversionKitTests"),
    ]
)
