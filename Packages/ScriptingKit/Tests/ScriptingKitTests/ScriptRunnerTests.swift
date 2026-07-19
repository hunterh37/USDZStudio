import Testing
import Foundation
@testable import ScriptingKit

/// In-memory `ScriptExecuting` fake: records the invocation, replays canned
/// stderr lines through the streaming callback, and returns a scripted result.
private final class MockExecutor: ScriptExecuting, @unchecked Sendable {
    var stdout = ""
    var stderrLines: [String] = []
    var exitCode: Int32 = 0
    var launchError: Error?

    private(set) var receivedScriptPath: String?
    private(set) var receivedArguments: [String] = []

    func execute(scriptPath: String, arguments: [String],
                 onStandardErrorLine: (@Sendable (String) -> Void)?) async throws -> ScriptProcessResult {
        if let launchError { throw launchError }
        receivedScriptPath = scriptPath
        receivedArguments = arguments
        for line in stderrLines { onStandardErrorLine?(line) }
        return ScriptProcessResult(exitCode: exitCode, standardOutput: stdout,
                                   standardError: stderrLines.joined(separator: "\n"))
    }
}

@Suite("ScriptRunner")
struct ScriptRunnerTests {

    private let fixedTemp: @Sendable (URL) -> URL = { _ in
        URL(fileURLWithPath: "/tmp/scripted-output.usdz")
    }

    private func runner(_ mock: MockExecutor) -> ScriptRunner {
        ScriptRunner(executor: mock, makeTemporaryOutput: fixedTemp)
    }

    // MARK: Manifest

    @Test func loadsManifestViaEmitFlag() async throws {
        let mock = MockExecutor()
        mock.stdout = #"{"name":"Audit","mutates":false}"#
        let manifest = try await runner(mock).loadManifest(
            script: URL(fileURLWithPath: "/s/audit.py"))
        #expect(manifest.name == "Audit")
        #expect(mock.receivedArguments == [ScriptRunner.emitManifestFlag])
        #expect(mock.receivedScriptPath == "/s/audit.py")
    }

    @Test func manifestLoadSurfacesBadJSON() async throws {
        let mock = MockExecutor()
        mock.stdout = "not json"
        await #expect(throws: ScriptRunError.self) {
            try await runner(mock).loadManifest(script: URL(fileURLWithPath: "/s/x.py"))
        }
    }

    // MARK: Argument building

    @Test func mutatingRunAddsOutputAndFlags() throws {
        let manifest = ScriptManifest(
            name: "Rename", mutates: true,
            arguments: [ScriptArgument(name: "pattern", kind: .string),
                        ScriptArgument(name: "lower", kind: .bool)])
        let (args, output) = try ScriptRunner.buildArguments(
            manifest: manifest,
            input: URL(fileURLWithPath: "/in/model.usdz"),
            options: .init(argumentValues: ["pattern": "^x", "lower": "true"]),
            makeTemporaryOutput: fixedTemp)
        #expect(args == ["/in/model.usdz", "-o", "/tmp/scripted-output.usdz",
                         "--pattern", "^x", "--lower"])
        #expect(output?.path == "/tmp/scripted-output.usdz")
    }

    @Test func dryRunSkipsOutput() throws {
        let manifest = ScriptManifest(name: "Rename", mutates: true)
        let (args, output) = try ScriptRunner.buildArguments(
            manifest: manifest,
            input: URL(fileURLWithPath: "/in/m.usda"),
            options: .init(dryRun: true),
            makeTemporaryOutput: fixedTemp)
        #expect(args == ["/in/m.usda", "--dry-run"])
        #expect(output == nil)
    }

    @Test func nonMutatingRunProducesNoOutput() throws {
        let manifest = ScriptManifest(name: "Audit", mutates: false)
        let (args, output) = try ScriptRunner.buildArguments(
            manifest: manifest,
            input: URL(fileURLWithPath: "/in/m.usda"),
            options: .init(),
            makeTemporaryOutput: fixedTemp)
        #expect(args == ["/in/m.usda"])
        #expect(output == nil)
    }

    @Test func falseBoolAndEmptyValuesAreOmitted() throws {
        let manifest = ScriptManifest(
            name: "X", mutates: false,
            arguments: [ScriptArgument(name: "lower", kind: .bool),
                        ScriptArgument(name: "pattern", kind: .string)])
        let args = try ScriptRunner.flagArguments(
            manifest: manifest,
            values: ["lower": "false", "pattern": "   "])
        #expect(args.isEmpty)
    }

    @Test func explicitOutputURLWins() throws {
        let manifest = ScriptManifest(name: "R", mutates: true)
        let (args, output) = try ScriptRunner.buildArguments(
            manifest: manifest,
            input: URL(fileURLWithPath: "/in/m.usdz"),
            options: .init(outputURL: URL(fileURLWithPath: "/out/final.usdz")),
            makeTemporaryOutput: fixedTemp)
        #expect(args.contains("/out/final.usdz"))
        #expect(output?.path == "/out/final.usdz")
    }

    @Test func unknownArgumentThrows() {
        let manifest = ScriptManifest(name: "X", mutates: false,
                                      arguments: [ScriptArgument(name: "known", kind: .string)])
        #expect(throws: ScriptRunError.unknownArgument("bogus")) {
            try ScriptRunner.flagArguments(manifest: manifest, values: ["bogus": "1"])
        }
    }

    // MARK: End-to-end run

    @Test func runStreamsProgressAndReturnsOutput() async throws {
        let mock = MockExecutor()
        mock.stderrLines = ["[  0%] starting", "renamed 3 prims",
                            "[ 50%] halfway", "[100%] done"]
        mock.stdout = "report"

        let events = EventBox()
        let result = try await runner(mock).run(
            script: URL(fileURLWithPath: "/s/rename.py"),
            manifest: ScriptManifest(name: "Rename", mutates: true),
            input: URL(fileURLWithPath: "/in/m.usdz"),
            onEvent: { events.append($0) })

        #expect(result.outputURL?.path == "/tmp/scripted-output.usdz")
        #expect(result.producedFile)
        #expect(result.log == ["renamed 3 prims"])
        #expect(result.lastProgress?.fraction == 1)
        #expect(result.standardOutput == "report")
        #expect(events.progressCount == 3)
    }

    @Test func nonZeroExitThrowsWithStderr() async throws {
        let mock = MockExecutor()
        mock.exitCode = 1
        mock.stderrLines = ["Traceback (most recent call last):", "ValueError: nope"]
        await #expect(throws: ScriptRunError.self) {
            try await runner(mock).run(
                script: URL(fileURLWithPath: "/s/x.py"),
                manifest: ScriptManifest(name: "X", mutates: true),
                input: URL(fileURLWithPath: "/in/m.usdz"))
        }
    }

    @Test func launchFailurePropagates() async {
        let mock = MockExecutor()
        struct Boom: Error {}
        mock.launchError = Boom()
        await #expect(throws: Boom.self) {
            try await runner(mock).run(
                script: URL(fileURLWithPath: "/s/x.py"),
                manifest: ScriptManifest(name: "X"),
                input: URL(fileURLWithPath: "/in/m.usdz"))
        }
    }
}

/// Thread-safe event collector for the streaming callback.
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ScriptRunEvent] = []
    func append(_ e: ScriptRunEvent) { lock.lock(); events.append(e); lock.unlock() }
    var progressCount: Int {
        lock.lock(); defer { lock.unlock() }
        return events.filter { if case .progress = $0 { return true }; return false }.count
    }
}
