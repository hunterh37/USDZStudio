// swift-tools-version:6.0
import PackageDescription

// Dev tooling, not a shipped product: the offscreen harness that drives the
// real editor views and documents without a window (Tools/EditorHarness/README.md).
let package = Package(
    name: "editor-harness",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "editor-harness", targets: ["editor-harness"])
    ],
    dependencies: [
        .package(path: "../../Packages/USDCore"),
        .package(path: "../../Packages/USDBridge"),
        .package(path: "../../Packages/EditingKit"),
        .package(path: "../../Packages/MeshKit"),
        .package(path: "../../Packages/EditorUI"),
    ],
    targets: [
        .executableTarget(
            name: "editor-harness",
            dependencies: ["USDCore", "USDBridge", "EditingKit", "MeshKit", "EditorUI"],
            path: "Sources"),
        .testTarget(name: "EditorHarnessTests", dependencies: ["editor-harness"], path: "Tests"),
    ]
)
