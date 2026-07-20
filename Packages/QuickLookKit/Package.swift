// swift-tools-version:6.0
// Spec: specs/quicklook.md
import PackageDescription

let package = Package(
    name: "QuickLookKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuickLookKit", targets: ["QuickLookKit"])
    ],
    targets: [
        // Pure Swift, zero internal dependencies. Holds the reusable render-plan
        // logic that the Finder-level QuickLook thumbnail/preview .appex targets
        // (thin, in App/) drive. Mirrors the CLI `thumbnail` usdrecord path.
        .target(name: "QuickLookKit", path: "Sources/QuickLookKit"),
        .testTarget(name: "QuickLookKitTests", dependencies: ["QuickLookKit"],
                    path: "Tests/QuickLookKitTests"),
    ]
)
