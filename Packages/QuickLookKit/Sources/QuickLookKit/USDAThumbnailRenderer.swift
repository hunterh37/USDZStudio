import Foundation

/// Reusable render-plan logic shared by the Finder-level QuickLook thumbnail and
/// preview extensions (`.appex` targets in `App/`). Pure and filesystem-agnostic
/// so it is fully unit-testable; the extensions supply the side effects (spawning
/// `usdrecord`, reading the PNG back). This mirrors the CLI `thumbnail` subcommand's
/// single-frame `usdrecord` path (`CLI/Sources/ThumbnailCommand.swift`) — the same
/// render pipeline, exposed as a library the .appex can link without pulling in the CLI.
public enum USDAThumbnailRenderer {

    /// File extensions QuickLook is registered to preview.
    public static let supportedExtensions = ["usd", "usda", "usdc", "usdz"]

    /// The concrete `usdrecord` invocation to render `source` to a PNG.
    public struct RenderPlan: Equatable, Sendable {
        /// Absolute path to the `usdrecord` executable.
        public let usdrecord: String
        /// argv (excluding the executable itself).
        public let arguments: [String]
        /// Absolute path of the PNG `usdrecord` will write.
        public let outputPath: String

        public init(usdrecord: String, arguments: [String], outputPath: String) {
            self.usdrecord = usdrecord
            self.arguments = arguments
            self.outputPath = outputPath
        }
    }

    public enum PlanError: Error, Equatable, Sendable {
        /// The file is not one of `supportedExtensions`.
        case unsupportedExtension(String)
        /// A non-positive maximum pixel size was requested.
        case invalidSize(Int)
        /// `usdrecord` could not be located (runtime not fetched / no override).
        case usdrecordNotFound
    }

    /// True when `url` has a QuickLook-supported USD extension.
    public static func canPreview(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Locate `usdrecord`, in priority order: the `DICYANIN_USDRECORD` override
    /// if set, else the binary beside the located Python interpreter (the venv
    /// layout that `scripts/fetch-python-runtime.sh` creates), else a scan of
    /// the system `PATH` (issue #110 — a working `/usr/bin/usdrecord` was never
    /// found because PATH was ignored). Returns `nil` if not found.
    public static func locateUsdrecord(
        environment: [String: String],
        locatePython: () -> String?,
        fileExists: (String) -> Bool
    ) -> String? {
        // 1. Explicit override wins; if set but missing, do not silently fall back.
        if let override = environment["DICYANIN_USDRECORD"], !override.isEmpty {
            return fileExists(override) ? override : nil
        }
        // Venv-adjacent binary (the fetch-python-runtime layout).
        if let python = locatePython() {
            let candidate = URL(fileURLWithPath: python).deletingLastPathComponent()
                .appendingPathComponent("usdrecord").path
            if fileExists(candidate) { return candidate }
        }
        // Final fallback: the first `usdrecord` on PATH (e.g. /usr/bin/usdrecord
        // from a system USD install). Only absolute PATH entries are considered.
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            guard directory.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("usdrecord").path
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// Build the `usdrecord` invocation that renders `source` to `outputPath` at
    /// `maximumPixelSize` on its longest edge. usdrecord's default camera
    /// auto-frames the stage bounds, so no camera math is needed.
    ///
    /// - Throws: `PlanError` for an unsupported extension, non-positive size, or
    ///   a missing `usdrecord` binary.
    public static func renderPlan(
        source: URL,
        outputPath: String,
        maximumPixelSize: Int,
        usdrecord: String?
    ) throws -> RenderPlan {
        let ext = source.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw PlanError.unsupportedExtension(ext)
        }
        guard maximumPixelSize > 0 else {
            throw PlanError.invalidSize(maximumPixelSize)
        }
        guard let usdrecord, !usdrecord.isEmpty else {
            throw PlanError.usdrecordNotFound
        }
        let standardizedSource = source.standardizedFileURL.path
        return RenderPlan(
            usdrecord: usdrecord,
            arguments: ["--imageWidth", String(maximumPixelSize),
                        standardizedSource, outputPath],
            outputPath: outputPath)
    }

    /// A stable, collision-resistant temporary PNG path for a render, derived
    /// from the source name and a unique token. Pure: the caller creates/cleans it.
    public static func temporaryOutputPath(
        for source: URL,
        token: String,
        temporaryDirectory: URL
    ) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        return temporaryDirectory
            .appendingPathComponent("\(base).\(token).png").path
    }
}
