import Foundation

/// How a single script run should be parameterised.
public struct ScriptRunOptions: Sendable {

    /// Where a mutating script writes its result. When `nil` and the script
    /// mutates, the runner allocates a temp file (same extension as the input,
    /// so `.usdz` packaging still works) and returns it in the result.
    public var outputURL: URL?

    /// Report intended changes without writing (`--dry-run`). Only meaningful
    /// for mutating scripts.
    public var dryRun: Bool

    /// User-entered values keyed by argument name. Empty strings mean "use the
    /// manifest default" and are skipped. Bool args are included as a presence
    /// flag only when truthy.
    public var argumentValues: [String: String]

    public init(outputURL: URL? = nil, dryRun: Bool = false,
                argumentValues: [String: String] = [:]) {
        self.outputURL = outputURL
        self.dryRun = dryRun
        self.argumentValues = argumentValues
    }
}

/// The outcome of a completed run.
public struct ScriptRunResult: Equatable, Sendable {

    /// The file the run produced, ready to re-import — `nil` for read-only
    /// (non-mutating) scripts and for dry runs.
    public let outputURL: URL?
    /// Everything the script wrote to stdout (e.g. a report).
    public let standardOutput: String
    /// Non-progress log lines, in order.
    public let log: [String]
    /// The last progress tick observed, if any.
    public let lastProgress: ScriptProgress?

    public init(outputURL: URL?, standardOutput: String, log: [String],
                lastProgress: ScriptProgress?) {
        self.outputURL = outputURL
        self.standardOutput = standardOutput
        self.log = log
        self.lastProgress = lastProgress
    }

    /// Whether there's a produced file to re-import into the scene.
    public var producedFile: Bool { outputURL != nil }
}

public enum ScriptRunError: Error, Equatable, CustomStringConvertible {
    /// The script named an argument that isn't in its manifest.
    case unknownArgument(String)
    /// `--emit-manifest` output wasn't valid manifest JSON.
    case malformedManifest(String)
    /// The interpreter ran but the script exited non-zero.
    case executionFailed(exitCode: Int32, message: String)

    public var description: String {
        switch self {
        case .unknownArgument(let name):
            return "Unknown script argument '\(name)'."
        case .malformedManifest(let detail):
            return "Could not read the script's manifest: \(detail)"
        case .executionFailed(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Script failed (exit \(code))." + (trimmed.isEmpty ? "" : "\n\(trimmed)")
        }
    }
}

/// Pure orchestration for running a bundled/user script headlessly against a
/// USD file: loads the manifest, builds the argument list, streams progress,
/// and hands back the produced file for re-import. All process I/O is delegated
/// to a `ScriptExecuting`, so this whole flow is unit-testable without Python.
public struct ScriptRunner: Sendable {

    /// The flag `_harness.py` recognises to print its manifest as JSON and exit.
    public static let emitManifestFlag = "--emit-manifest"

    private let executor: any ScriptExecuting
    private let makeTemporaryOutput: @Sendable (URL) -> URL

    public init(executor: any ScriptExecuting,
                makeTemporaryOutput: @escaping @Sendable (URL) -> URL = ScriptRunner.defaultTemporaryOutput) {
        self.executor = executor
        self.makeTemporaryOutput = makeTemporaryOutput
    }

    /// Asks the script to describe itself so the UI can build a parameter sheet
    /// and decide whether to offer a re-import.
    public func loadManifest(script: URL) async throws -> ScriptManifest {
        let result = try await executor.execute(
            scriptPath: script.path,
            arguments: [Self.emitManifestFlag],
            onStandardErrorLine: nil)
        guard result.succeeded else {
            throw ScriptRunError.executionFailed(exitCode: result.exitCode,
                                                 message: result.standardError)
        }
        guard let data = result.standardOutput.data(using: .utf8) else {
            // coverage:disable — unreachable: standardOutput is a Swift String, which always encodes to UTF-8; kept as a defensive guard.
            throw ScriptRunError.malformedManifest("non-UTF8 output")
        }
        do {
            return try ScriptManifest.decode(fromJSON: data)
        } catch {
            throw ScriptRunError.malformedManifest(String(describing: error))
        }
    }

    /// Runs `script` against `input`, streaming `onEvent` as the script emits
    /// progress/log lines. Returns the produced file (if any) for re-import.
    @discardableResult
    public func run(
        script: URL,
        manifest: ScriptManifest,
        input: URL,
        options: ScriptRunOptions = .init(),
        onEvent: (@Sendable (ScriptRunEvent) -> Void)? = nil
    ) async throws -> ScriptRunResult {

        let (arguments, expectedOutput) = try Self.buildArguments(
            manifest: manifest, input: input, options: options,
            makeTemporaryOutput: makeTemporaryOutput)

        // Collect log/progress alongside the streamed callback.
        let sink = EventSink()
        let result = try await executor.execute(
            scriptPath: script.path,
            arguments: arguments,
            onStandardErrorLine: { line in
                let event = ScriptRunEvent.classify(line: line)
                sink.record(event)
                onEvent?(event)
            })

        guard result.succeeded else {
            throw ScriptRunError.executionFailed(exitCode: result.exitCode,
                                                 message: result.standardError)
        }
        return ScriptRunResult(
            outputURL: expectedOutput,
            standardOutput: result.standardOutput,
            log: sink.logLines,
            lastProgress: sink.lastProgress)
    }

    /// Builds the CLI argument vector the harness expects. Split out (and
    /// `static`) so argument construction is independently testable.
    static func buildArguments(
        manifest: ScriptManifest,
        input: URL,
        options: ScriptRunOptions,
        makeTemporaryOutput: (URL) -> URL
    ) throws -> (arguments: [String], expectedOutput: URL?) {

        var arguments = [input.path]
        var expectedOutput: URL?

        if manifest.mutates {
            if options.dryRun {
                arguments.append("--dry-run")
            } else {
                let output = options.outputURL ?? makeTemporaryOutput(input)
                arguments.append(contentsOf: ["-o", output.path])
                expectedOutput = output
            }
        }

        arguments.append(contentsOf: try flagArguments(manifest: manifest,
                                                        values: options.argumentValues))
        return (arguments, expectedOutput)
    }

    /// Converts user values into `--flag value` pairs, validating names and
    /// honouring the harness's bool-as-presence-flag convention.
    static func flagArguments(manifest: ScriptManifest,
                              values: [String: String]) throws -> [String] {
        var out: [String] = []
        // Deterministic order: manifest declaration order.
        for argument in manifest.arguments {
            guard let raw = values[argument.name] else { continue }
            switch argument.kind {
            case .bool:
                if ScriptArgument.isTruthy(raw) { out.append(argument.flag) }
            case .int, .float, .string:
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }   // fall back to manifest default
                out.append(contentsOf: [argument.flag, raw])
            }
        }
        // Any provided key with no matching manifest argument is a caller error.
        let known = Set(manifest.arguments.map(\.name))
        if let stray = values.keys.first(where: { !known.contains($0) }) {
            throw ScriptRunError.unknownArgument(stray)
        }
        return out
    }

    /// Default temp output: unique directory, input basename preserved so the
    /// extension (and thus `.usdz` packaging) is retained.
    public static let defaultTemporaryOutput: @Sendable (URL) -> URL = { input in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicyanin-script-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.isEmpty ? "usda" : input.pathExtension
        return dir.appendingPathComponent("\(base)-scripted.\(ext)")
    }
}

/// Accumulates streamed events so the final result carries the full log and the
/// last progress tick. A reference type shared into the `@Sendable` closure;
/// the executor invokes the callback serially per process, so a plain array is
/// safe here. Marked `@unchecked Sendable` to cross the closure boundary.
private final class EventSink: @unchecked Sendable {
    private(set) var logLines: [String] = []
    private(set) var lastProgress: ScriptProgress?
    private let lock = NSLock()

    func record(_ event: ScriptRunEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .log(let line): logLines.append(line)
        case .progress(let p): lastProgress = p
        }
    }
}
