// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MechanismKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MechanismKit", targets: ["MechanismKit"])
    ],
    targets: [
        // Pure Swift, zero internal dependencies (specs/articulation-mechanisms.md).
        // Rigid-body articulation math: hinge/slider joints, pivot transforms,
        // machine-checkable invariants. No UI/GPU/Python, like MeshKit/USDCore.
        .target(name: "MechanismKit", path: "Sources/MechanismKit"),
        .testTarget(name: "MechanismKitTests", dependencies: ["MechanismKit"],
                    path: "Tests/MechanismKitTests"),
    ]
)
