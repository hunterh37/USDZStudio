import Foundation
import USDCore

/// Save/Save As (roadmap Phase 3; the missing link between "editing works" and
/// "editing is useful" for imported files).
///
/// `.usda`/`.usd` are authored entirely in Swift via `USDASerializer` — pure,
/// deterministic, no interpreter needed. `.usdc`/`.usdz` author the same
/// `.usda` to a temp file and hand format conversion to USD's own core via
/// `stage_save.py`, so binary/packaged output is always produced by the
/// reference implementation, never a reimplementation.
public enum StageSaver {

    public static let supportedExtensions: Set<String> = ["usda", "usd", "usdc", "usdz"]

    public enum SaveError: Error, Equatable, CustomStringConvertible {
        case unsupportedExtension(String)
        case pythonRequired(String)

        public var description: String {
            switch self {
            case .unsupportedExtension(let ext):
                return "Cannot save '.\(ext)' — supported: usda, usd, usdc, usdz."
            case .pythonRequired(let ext):
                return "Saving '.\(ext)' needs a Python with usd-core (the same dependency as Open…)."
            }
        }
    }

    /// Serializes `stage` and writes it to `url` (format from the extension).
    /// Atomic for text formats; conversion output is written by USD itself.
    public static func save(
        _ stage: some USDStageProtocol,
        to url: URL,
        executor: ProcessBridgeExecutor?
    ) async throws {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw SaveError.unsupportedExtension(ext)
        }
        let usda = USDASerializer.serialize(stage)

        if ext == "usda" || ext == "usd" {
            try usda.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let executor else { throw SaveError.pythonRequired(ext) }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicyanin-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let staged = tempDirectory.appendingPathComponent("stage.usda")
        try usda.write(to: staged, atomically: true, encoding: .utf8)

        // usdz packaging refuses to overwrite; convert to a temp product then
        // move into place so a failed save never clobbers the existing file.
        let product = tempDirectory.appendingPathComponent("out.\(ext)")
        _ = try await executor.runScript(
            Self.saveScriptPath(near: executor.scriptPath),
            arguments: [staged.path, product.path])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: product)
        } else {
            try FileManager.default.moveItem(at: product, to: url)
        }
    }

    /// `stage_save.py` ships beside `stage_snapshot.py`.
    static func saveScriptPath(near snapshotScript: String) -> String {
        URL(fileURLWithPath: snapshotScript)
            .deletingLastPathComponent()
            .appendingPathComponent("stage_save.py")
            .path
    }
}

extension ProcessBridgeExecutor {
    /// Runs an arbitrary bridge script with this executor's interpreter —
    /// the same process plumbing `snapshotJSON` uses.
    public func runScript(_ script: String, arguments: [String]) async throws -> Data {
        try await runProcess(arguments: [script] + arguments)
    }
}
