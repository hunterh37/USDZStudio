// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DicyaninUSDZEditorApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Packages/EditorUI"),
        .package(path: "../Packages/USDBridge"),
        .package(path: "../Packages/USDCore"),
    ],
    targets: [
        .executableTarget(
            name: "DicyaninUSDZEditorApp",
            dependencies: ["EditorUI", "USDBridge", "USDCore"],
            path: "Sources")
    ]
)
