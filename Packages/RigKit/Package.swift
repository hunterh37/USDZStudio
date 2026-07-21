// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RigKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RigKit", targets: ["RigKit"])
    ],
    targets: [
        // Pure Swift, zero internal dependencies (specs/animation-rigging.md).
        // Skeletal rig / skinning / motion math: FK, IK/FK solvers, constraints,
        // auto-rig fit + weight solve, humanoid retargeting, clip blending, and a
        // deterministic motion-quality metric — all machine-checkable invariants.
        // No UI/GPU/Python, like MeshKit/MechanismKit/USDCore.
        .target(name: "RigKit", path: "Sources/RigKit"),
        .testTarget(name: "RigKitTests", dependencies: ["RigKit"],
                    path: "Tests/RigKitTests"),
    ]
)
