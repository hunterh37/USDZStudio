// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeshKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeshKit", targets: ["MeshKit"])
    ],
    targets: [
        // Pure Swift, zero dependencies (specs/mesh-editing.md).
        .target(name: "MeshKit", path: "Sources/MeshKit"),
        .testTarget(name: "MeshKitTests", dependencies: ["MeshKit"], path: "Tests/MeshKitTests",
                    resources: [.copy("Golden")]),
    ]
)
