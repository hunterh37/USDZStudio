// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ViewportKit",
    // macOS 15: LowLevelMesh (GPU-resident, partially-updatable geometry) powers
    // the live vertex edit mode's million-vertex path (specs/viewport.md).
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ViewportKit", targets: ["ViewportKit"])
    ],
    dependencies: [
        .package(path: "../USDCore"),
        .package(path: "../MeshKit"),
        .package(path: "../MechanismKit")
    ],
    targets: [
        .target(name: "ViewportKit", dependencies: ["USDCore", "MeshKit", "MechanismKit"], path: "Sources/ViewportKit"),
        .testTarget(name: "ViewportKitTests", dependencies: ["ViewportKit", "MechanismKit"], path: "Tests/ViewportKitTests"),
    ]
)
