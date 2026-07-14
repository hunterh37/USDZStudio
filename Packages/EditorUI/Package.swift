// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EditorUI",
    platforms: [.macOS(.v14)],
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
    ],
    targets: [
        .target(
            name: "EditorUI",
            dependencies: [
                "USDCore", "USDBridge", "ViewportKit", "EditingKit",
                "ConversionKit", "ValidationKit", "ScriptingKit",
                "DicyaninDesignSystem",
            ],
            path: "Sources/EditorUI"),
        .testTarget(name: "EditorUITests", dependencies: ["EditorUI"], path: "Tests/EditorUITests"),
    ]
)
