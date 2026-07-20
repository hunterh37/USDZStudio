import Foundation
import AppKit
import QuickLookKit

/// Bridges the pure `QuickLookKit` render-plan logic to the side-effecting world:
/// locates `usdrecord` (env override → runtime bundled inside the host app), spawns
/// it to render a `.usd*` file to a temporary PNG, and loads the PNG back as an
/// `NSImage`. Compiled into both the thumbnail and preview `.appex` targets.
///
/// The host app is NOT sandboxed (see specs/architecture.md §App Distribution), so
/// the embedded extensions may freely spawn `usdrecord` from the bundled Python
/// runtime — the same pipeline the CLI `thumbnail` subcommand uses.
enum QuickLookRenderService {

    enum RenderError: Error {
        case usdrecordFailed(Int32)
        case noOutputProduced
        case imageDecodeFailed
    }

    /// Render `source` to an `NSImage` sized so its longest edge is at most
    /// `maximumPixelSize`. Blocking; call off the main thread.
    static func renderImage(source: URL, maximumPixelSize: Int) throws -> NSImage {
        let tmpDir = FileManager.default.temporaryDirectory
        let output = USDAThumbnailRenderer.temporaryOutputPath(
            for: source,
            token: UUID().uuidString,
            temporaryDirectory: tmpDir)
        defer { try? FileManager.default.removeItem(atPath: output) }

        let usdrecord = USDAThumbnailRenderer.locateUsdrecord(
            environment: ProcessInfo.processInfo.environment,
            locatePython: locateBundledPython,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) })

        let plan = try USDAThumbnailRenderer.renderPlan(
            source: source,
            outputPath: output,
            maximumPixelSize: maximumPixelSize,
            usdrecord: usdrecord)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.usdrecord)
        process.arguments = plan.arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RenderError.usdrecordFailed(process.terminationStatus)
        }
        guard FileManager.default.fileExists(atPath: plan.outputPath) else {
            throw RenderError.noOutputProduced
        }
        guard let image = NSImage(contentsOfFile: plan.outputPath) else {
            throw RenderError.imageDecodeFailed
        }
        return image
    }

    /// The Python interpreter bundled with the host app. The extension lives at
    /// `HostApp.app/Contents/PlugIns/<ext>.appex`; the runtime ships at
    /// `HostApp.app/Contents/Resources/Python/runtime/bin/python3`. Walk up from
    /// the extension bundle to the host `.app`, then into its Resources.
    static func locateBundledPython() -> String? {
        var url = Bundle.main.bundleURL
        // .../Contents/PlugIns/<ext>.appex → climb to the host .app bundle.
        while url.pathExtension != "app" && url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        guard url.pathExtension == "app" else { return nil }
        let candidate = url
            .appendingPathComponent("Contents/Resources/Python/runtime/bin/python3")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}
