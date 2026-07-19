import Foundation
import USDBridge
import ScriptingKit

/// Production `ScriptExecuting`: spawns the located Python interpreter with a
/// user/bundled script, streaming stderr line-by-line so `app.progress` ticks
/// reach the UI live. Reuses the interpreter `ProcessBridgeExecutor` already
/// located, and sets `PYTHONPATH` to the script's directory so `_harness`
/// imports (the same discipline as the CLI `run` subcommand).
public struct ProcessScriptExecutor: ScriptExecuting {

    private let pythonPath: String

    public init(pythonPath: String) {
        self.pythonPath = pythonPath
    }

    /// Builds from the same executor `open`/`save` use, so a single located
    /// interpreter serves the whole app. Returns `nil` when no Python exists.
    public init?(bridge: ProcessBridgeExecutor?) {
        guard let bridge else { return nil }
        self.init(pythonPath: bridge.pythonPath)
    }

    public func execute(
        scriptPath: String,
        arguments: [String],
        onStandardErrorLine: (@Sendable (String) -> Void)?
    ) async throws -> ScriptProcessResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + arguments

        // Make `_harness` importable: prepend the script's directory to any
        // inherited PYTHONPATH.
        var environment = ProcessInfo.processInfo.environment
        let scriptDir = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().path
        environment["PYTHONPATH"] = ([scriptDir] + (environment["PYTHONPATH"].map { [$0] } ?? []))
            .joined(separator: ":")
        // Unbuffered stdout/stderr so progress ticks arrive promptly, not at exit.
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulators guarded by a lock — the readability handlers fire on
        // arbitrary queues.
        let collector = OutputCollector(onStandardErrorLine: onStandardErrorLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.appendStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.appendStderr(data)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ScriptExecutorError.launchFailed(pythonPath: pythonPath,
                                                   detail: error.localizedDescription)
        }

        // Await termination without blocking a thread.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        // Drain anything left in the pipes after exit, then detach handlers.
        collector.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        collector.finish()

        return ScriptProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: collector.standardOutput,
            standardError: collector.standardError)
    }
}

public enum ScriptExecutorError: Error, CustomStringConvertible {
    case launchFailed(pythonPath: String, detail: String)

    public var description: String {
        switch self {
        case .launchFailed(let path, let detail):
            return "Could not launch Python at \(path): \(detail)"
        }
    }
}

/// Thread-safe sink for the two pipes: accumulates stdout, and splits stderr
/// into whole lines (via `LineBuffer`) forwarded to the streaming callback.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stderrLineBuffer = LineBuffer()
    private let onStandardErrorLine: (@Sendable (String) -> Void)?

    init(onStandardErrorLine: (@Sendable (String) -> Void)?) {
        self.onStandardErrorLine = onStandardErrorLine
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); stdoutData.append(data); lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrData.append(data)
        let lines = stderrLineBuffer.append(String(decoding: data, as: UTF8.self))
        lock.unlock()
        for line in lines { onStandardErrorLine?(line) }
    }

    func finish() {
        lock.lock()
        let tail = stderrLineBuffer.flush()
        lock.unlock()
        if let tail { onStandardErrorLine?(tail) }
    }

    var standardOutput: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stdoutData, as: UTF8.self)
    }

    var standardError: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }
}
