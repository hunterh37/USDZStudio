import Foundation
import USDCore

/// Executor seam between `BridgedStage` and the Python runtime.
///
/// Phase 0 backend: `ProcessBridgeExecutor` (subprocess running
/// `stage_snapshot.py`). The spec's target backend is an in-process libpython
/// interpreter on a dedicated thread (specs/usd-bridge.md); it will implement
/// this same protocol, so nothing downstream changes when it lands.
public protocol BridgeExecutor: Sendable {
    /// Emits the JSON snapshot payload for the USD file at `url`.
    func snapshotJSON(forFileAt url: URL) async throws -> Data
    /// Verifies `import pxr` works.
    func checkAvailability() async -> BridgeAvailability
}

/// A stage opened through the Python/usd-core bridge, exposed to the rest of
/// the app as an immutable snapshot (mutation lands with EditingKit, Phase 3).
public struct BridgedStage: USDStageProtocol {

    public let snapshot: StageSnapshot

    public var sourceURL: URL? { snapshot.sourceURL }
    public var metadata: StageMetadata { snapshot.metadata }
    public var rootPrims: [Prim] { snapshot.rootPrims }

    init(snapshot: StageSnapshot) {
        self.snapshot = snapshot
    }

    /// File extensions the bridge will open (`.reality` is viewer-only and
    /// handled natively by ViewportKit, not the bridge).
    public static let supportedExtensions: Set<String> = ["usdz", "usda", "usdc", "usd"]

    /// Opens a USD document and snapshots its prim tree.
    public static func open(url: URL, executor: any BridgeExecutor) async throws -> BridgedStage {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw BridgeError.unreadableFile(path: url.path)
        }
        let data = try await executor.snapshotJSON(forFileAt: url)
        return BridgedStage(snapshot: try StageSnapshotDecoder.decode(data, sourceURL: url))
    }
}

/// Phase 0 executor: spawns the located Python interpreter with the bundled
/// `stage_snapshot.py` and captures its stdout.
public struct ProcessBridgeExecutor: BridgeExecutor {

    public var pythonPath: String
    public var scriptPath: String

    public init(pythonPath: String, scriptPath: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
    }

    /// Builds an executor from the locator, or `nil` when no interpreter exists.
    public init?(locator: PythonRuntimeLocator = PythonRuntimeLocator(), scriptPath: String) {
        guard let python = locator.locate() else { return nil }
        self.init(pythonPath: python, scriptPath: scriptPath)
    }

    public func snapshotJSON(forFileAt url: URL) async throws -> Data {
        try await run(arguments: [scriptPath, url.path])
    }

    public func checkAvailability() async -> BridgeAvailability {
        do {
            _ = try await run(arguments: ["-c", "import pxr"])
            return .available(pythonPath: pythonPath)
        } catch {
            return .unavailable(reason: (error as? BridgeError)?.errorDescription
                ?? String(describing: error))
        }
    }

    private func run(arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw BridgeError.pythonUnavailable(detail: "failed to launch \(pythonPath): \(error.localizedDescription)")
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.executionFailed(
                pythonTraceback: String(data: errData, encoding: .utf8) ?? "<no stderr>")
        }
        return outData
    }
}
