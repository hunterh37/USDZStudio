// swift-tools-version:6.0
// Spec: specs/architecture.md — shared `render_views` backends (native SceneKit
// + opt-in usdrecord) so BOTH the CLI- and app-hosted MCP servers get a
// renderer (issue #109). Depends on AgentMCP for the `RenderExecuting` contract.
import PackageDescription

let package = Package(
    name: "RenderKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RenderKit", targets: ["RenderKit"])
    ],
    dependencies: [
        .package(path: "../AgentMCP"),
        .package(path: "../USDBridge"),
    ],
    targets: [
        .target(
            name: "RenderKit",
            dependencies: ["AgentMCP", "USDBridge"],
            path: "Sources/RenderKit"),
        .testTarget(
            name: "RenderKitTests",
            dependencies: ["RenderKit", "AgentMCP"],
            path: "Tests/RenderKitTests"),
    ]
)
