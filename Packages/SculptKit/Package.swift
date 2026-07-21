// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SculptKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SculptKit", targets: ["SculptKit"])
    ],
    dependencies: [
        .package(path: "../USDCore"),
        .package(path: "../MeshKit"),
        .package(path: "../MechanismKit"),
    ],
    targets: [
        .target(name: "SculptKit", dependencies: ["USDCore", "MeshKit", "MechanismKit"], path: "Sources/SculptKit"),
        .testTarget(name: "SculptKitTests", dependencies: ["SculptKit"], path: "Tests/SculptKitTests"),
    ]
)
