// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "openusdz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openusdz", targets: ["openusdz"])
    ],
    dependencies: [
        // Kits only — never EditorUI (specs/architecture.md dependency rules).
        .package(path: "../Packages/USDCore"),
        .package(path: "../Packages/USDBridge"),
        .package(path: "../Packages/ValidationKit"),
        .package(path: "../Packages/ConversionKit"),
        .package(path: "../Packages/MeshKit"),
    ],
    targets: [
        .executableTarget(
            name: "openusdz",
            dependencies: ["USDCore", "USDBridge", "ValidationKit", "ConversionKit", "MeshKit"],
            path: "Sources"),
        .testTarget(name: "CLITests", dependencies: ["openusdz"], path: "Tests"),
    ]
)
