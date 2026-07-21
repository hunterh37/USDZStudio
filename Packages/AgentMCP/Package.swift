// swift-tools-version:6.0
// Spec: docs/AGENT_MCP_PLAN.md — typed, transactional, verification-gated
// MCP editing API over the kits (specs/architecture.md dependency rules).
import PackageDescription

let package = Package(
    name: "AgentMCP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentMCP", targets: ["AgentMCP"])
    ],
    dependencies: [
        // Kits only — never EditorUI (specs/architecture.md dependency rules).
        .package(path: "../USDCore"),
        .package(path: "../USDBridge"),
        .package(path: "../EditingKit"),
        .package(path: "../ValidationKit"),
        .package(path: "../ConversionKit"),
        .package(path: "../ScriptingKit"),
        .package(path: "../MeshKit"),
        .package(path: "../MechanismKit"),
        .package(path: "../SculptKit"),
        .package(path: "../RigKit"),
    ],
    targets: [
        .target(
            name: "AgentMCP",
            dependencies: [
                "USDCore", "USDBridge", "EditingKit", "ValidationKit",
                "ConversionKit", "ScriptingKit", "MeshKit", "MechanismKit", "SculptKit", "RigKit",
            ],
            path: "Sources/AgentMCP"),
        .testTarget(
            name: "AgentMCPTests",
            dependencies: ["AgentMCP"],
            path: "Tests/AgentMCPTests"),
    ]
)
