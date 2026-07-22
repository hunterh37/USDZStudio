// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "USDZStudioApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/EditorUI"),
        .package(path: "../Packages/USDBridge"),
        .package(path: "../Packages/USDCore"),
        .package(path: "../Packages/AgentMCP"),
        .package(path: "../Packages/RenderKit"),
        .package(path: "../Packages/DiagnosticsKit"),
    ],
    targets: [
        .executableTarget(
            name: "USDZStudioApp",
            dependencies: ["EditorUI", "USDBridge", "USDCore", "AgentMCP", "RenderKit", "DiagnosticsKit"],
            path: "Sources")
    ]
)
