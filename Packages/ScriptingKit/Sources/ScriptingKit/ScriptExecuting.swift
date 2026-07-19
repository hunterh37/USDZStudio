import Foundation

/// Result of running a script process to completion.
public struct ScriptProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    /// Full captured stderr, for surfacing a traceback when the run fails.
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// The seam between `ScriptRunner` (pure orchestration) and the interpreter.
///
/// The production conformer lives in the app layer (it wraps
/// `USDBridge.ProcessBridgeExecutor`, sets `PYTHONPATH` so `_harness` imports,
/// and streams stderr line-by-line for live progress). Keeping this a protocol
/// lets the runner be exercised end-to-end in unit tests against an in-memory
/// fake — no Python required.
public protocol ScriptExecuting: Sendable {

    /// Runs the Python file at `scriptPath` with `arguments`, invoking
    /// `onStandardErrorLine` for each stderr line as it arrives (for live
    /// progress). Returns once the process exits. Throws only when the process
    /// cannot be launched — a non-zero exit is reported via the result.
    func execute(
        scriptPath: String,
        arguments: [String],
        onStandardErrorLine: (@Sendable (String) -> Void)?
    ) async throws -> ScriptProcessResult
}
