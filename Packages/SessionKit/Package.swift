// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SessionKit",
    // macOS 15: SessionKit's ViewState reuses ViewportKit value types
    // (EnvironmentSettings, ViewportCameraPose), and ViewportKit requires
    // macOS 15 for the LowLevelMesh live-edit path (specs/mesh-editing.md).
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SessionKit", targets: ["SessionKit"])
    ],
    dependencies: [
        .package(path: "../USDCore"),
        .package(path: "../ViewportKit"),
        .package(path: "../EditingKit"),
    ],
    targets: [
        .target(
            name: "SessionKit",
            dependencies: ["USDCore", "ViewportKit", "EditingKit"],
            path: "Sources/SessionKit"),
        .testTarget(
            name: "SessionKitTests",
            dependencies: ["SessionKit"],
            path: "Tests/SessionKitTests"),
    ]
)
