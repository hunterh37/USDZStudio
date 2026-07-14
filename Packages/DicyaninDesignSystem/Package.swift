// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DicyaninDesignSystem",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DicyaninDesignSystem", targets: ["DicyaninDesignSystem"])
    ],
    targets: [
        .target(name: "DicyaninDesignSystem", path: "Sources/DicyaninDesignSystem"),
        .testTarget(
            name: "DicyaninDesignSystemTests",
            dependencies: ["DicyaninDesignSystem"],
            path: "Tests/DicyaninDesignSystemTests"),
    ]
)
