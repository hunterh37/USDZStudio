import Testing
import Foundation
@testable import EditorUI

/// Unit coverage for the pure export-target math and format metadata backing
/// the one-click export button and the advanced export panel.
struct ExportPlanTests {

    // MARK: ExportFormat metadata

    @Test func allCasesCoverKnownFormats() {
        #expect(ExportFormat.allCases == [.usdz, .usda, .usdc])
    }

    @Test func rawValueMatchesFileExtensionAndID() {
        for format in ExportFormat.allCases {
            #expect(format.fileExtension == format.rawValue)
            #expect(format.id == format.rawValue)
        }
    }

    @Test func displayNameIsUppercasedToken() {
        #expect(ExportFormat.usdz.displayName == "USDZ")
        #expect(ExportFormat.usda.displayName == "USDA")
        #expect(ExportFormat.usdc.displayName == "USDC")
    }

    @Test func everyFormatHasNonEmptyDetailAndSymbol() {
        for format in ExportFormat.allCases {
            #expect(!format.detail.isEmpty)
            #expect(!format.systemImage.isEmpty)
        }
    }

    @Test func distinctSymbolsPerFormat() {
        #expect(ExportFormat.usdz.systemImage == "shippingbox")
        #expect(ExportFormat.usda.systemImage == "doc.plaintext")
        #expect(ExportFormat.usdc.systemImage == "cube")
    }

    @Test func onlyTextFormatSkipsBridge() {
        #expect(ExportFormat.usda.requiresBridge == false)
        #expect(ExportFormat.usdz.requiresBridge == true)
        #expect(ExportFormat.usdc.requiresBridge == true)
    }

    // MARK: smartDestination — open file

    @Test func destinationSitsBesideSourceReusingBaseName() {
        let source = URL(fileURLWithPath: "/Users/me/models/robot.usdz")
        let fallback = URL(fileURLWithPath: "/Users/me/Desktop")
        let dest = ExportPlan.smartDestination(
            sourceURL: source, format: .usdz, fallbackDirectory: fallback)
        #expect(dest.path == "/Users/me/models/robot.usdz")
    }

    @Test func destinationExtensionMatchesRequestedFormat() {
        let source = URL(fileURLWithPath: "/Users/me/models/robot.glb")
        let fallback = URL(fileURLWithPath: "/Users/me/Desktop")
        let dest = ExportPlan.smartDestination(
            sourceURL: source, format: .usda, fallbackDirectory: fallback)
        #expect(dest.lastPathComponent == "robot.usda")
        #expect(dest.deletingLastPathComponent().path == "/Users/me/models")
    }

    // MARK: smartDestination — untitled scene

    @Test func untitledFallsBackToFallbackDirectoryAndName() {
        let fallback = URL(fileURLWithPath: "/Users/me/Desktop")
        let dest = ExportPlan.smartDestination(
            sourceURL: nil, format: .usdc, fallbackDirectory: fallback)
        #expect(dest.path == "/Users/me/Desktop/Untitled.usdc")
    }

    @Test func untitledHonorsCustomBaseName() {
        let fallback = URL(fileURLWithPath: "/tmp")
        let dest = ExportPlan.smartDestination(
            sourceURL: nil, format: .usdz, fallbackDirectory: fallback,
            untitledBaseName: "Scratch")
        #expect(dest.lastPathComponent == "Scratch.usdz")
    }

    @Test func trailingSlashSourceStillReusesDirectoryName() {
        // A directory-style source URL resolves its last path component as the
        // base name (Foundation normalizes the trailing slash away).
        let source = URL(fileURLWithPath: "/Users/me/models/")
        let fallback = URL(fileURLWithPath: "/tmp")
        let dest = ExportPlan.smartDestination(
            sourceURL: source, format: .usdz, fallbackDirectory: fallback)
        #expect(dest.lastPathComponent == "models.usdz")
    }

    // MARK: smart() convenience

    @Test func smartPlanBundlesDestinationAndFormat() {
        let source = URL(fileURLWithPath: "/Users/me/a/thing.usdc")
        let fallback = URL(fileURLWithPath: "/Users/me/Desktop")
        let plan = ExportPlan.smart(
            sourceURL: source, format: .usdz, fallbackDirectory: fallback)
        #expect(plan.format == .usdz)
        #expect(plan.destination.lastPathComponent == "thing.usdz")
    }

    @Test func planIsValueEquatable() {
        let url = URL(fileURLWithPath: "/tmp/x.usdz")
        let a = ExportPlan(destination: url, format: .usdz)
        let b = ExportPlan(destination: url, format: .usdz)
        let c = ExportPlan(destination: url, format: .usda)
        #expect(a == b)
        #expect(a != c)
    }
}
