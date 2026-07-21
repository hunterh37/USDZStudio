// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EditorUI",
    // macOS 15: EditorUI hosts ViewportKit, which requires macOS 15 for the
    // LowLevelMesh live vertex edit path (specs/mesh-editing.md §Live vertex edit).
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EditorUI", targets: ["EditorUI"])
    ],
    dependencies: [
        .package(path: "../USDCore"),
        .package(path: "../USDBridge"),
        .package(path: "../ViewportKit"),
        .package(path: "../EditingKit"),
        .package(path: "../ConversionKit"),
        .package(path: "../ValidationKit"),
        .package(path: "../ScriptingKit"),
        .package(path: "../DicyaninDesignSystem"),
        .package(path: "../MeshKit"),
        .package(path: "../SculptKit"),
        .package(path: "../SessionKit"),
    ],
    targets: [
        .target(
            name: "EditorUI",
            dependencies: [
                "USDCore", "USDBridge", "ViewportKit", "EditingKit",
                "ConversionKit", "ValidationKit", "ScriptingKit",
                "DicyaninDesignSystem", "MeshKit", "SculptKit", "SessionKit",
            ],
            path: "Sources/EditorUI"),
        .testTarget(name: "EditorUITests", dependencies: ["EditorUI"], path: "Tests/EditorUITests"),
    ]
)
