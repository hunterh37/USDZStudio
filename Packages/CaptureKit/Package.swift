// swift-tools-version:6.0
// Spec: specs/capture-import.md — Phase 2.5 Capture Import (Photos → USDZ).
import PackageDescription

let package = Package(
    name: "CaptureKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"])
    ],
    dependencies: [
        // Pure-Swift leaf: the capture-planner logic depends only on the value
        // types in USDCore/MeshKit, never on UI/GPU/Python (specs/architecture.md).
        .package(path: "../USDCore"),
        .package(path: "../MeshKit"),
    ],
    targets: [
        .target(name: "CaptureKit", dependencies: ["USDCore", "MeshKit"], path: "Sources/CaptureKit"),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"], path: "Tests/CaptureKitTests"),
    ]
)
