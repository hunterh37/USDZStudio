// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScriptingKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScriptingKit", targets: ["ScriptingKit"])
    ],
    dependencies: [
        .package(path: "../USDCore")
    ],
    targets: [
        .target(name: "ScriptingKit", dependencies: ["USDCore"], path: "Sources/ScriptingKit"),
        .testTarget(name: "ScriptingKitTests", dependencies: ["ScriptingKit"], path: "Tests/ScriptingKitTests"),
    ]
)
