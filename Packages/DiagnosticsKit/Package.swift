// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DiagnosticsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiagnosticsKit", targets: ["DiagnosticsKit"])
    ],
    targets: [
        // Pure Swift, zero internal dependencies (specs/diagnostics-logging.md).
        // Per-session breadcrumb logging + crash-sentinel detection. No UI/GPU/
        // Python — a leaf like MechanismKit, so every layer can adopt it.
        .target(name: "DiagnosticsKit", path: "Sources/DiagnosticsKit"),
        .testTarget(name: "DiagnosticsKitTests", dependencies: ["DiagnosticsKit"],
                    path: "Tests/DiagnosticsKitTests"),
    ]
)
