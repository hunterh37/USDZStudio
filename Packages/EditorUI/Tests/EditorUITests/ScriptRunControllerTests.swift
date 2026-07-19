import Testing
import Foundation
import ScriptingKit
@testable import EditorUI

/// Fake interpreter: answers `--emit-manifest` with canned JSON and any other
/// invocation with scripted stderr/stdout, so the controller can be driven with
/// no Python present.
private final class FakeExecutor: ScriptExecuting, @unchecked Sendable {
    var manifestJSON: String
    var runStderr: [String]
    var runStdout: String
    var runExit: Int32

    init(manifestJSON: String, runStderr: [String] = [],
         runStdout: String = "", runExit: Int32 = 0) {
        self.manifestJSON = manifestJSON
        self.runStderr = runStderr
        self.runStdout = runStdout
        self.runExit = runExit
    }

    func execute(scriptPath: String, arguments: [String],
                 onStandardErrorLine: (@Sendable (String) -> Void)?) async throws -> ScriptProcessResult {
        if arguments.contains(ScriptRunner.emitManifestFlag) {
            return ScriptProcessResult(exitCode: 0, standardOutput: manifestJSON, standardError: "")
        }
        for line in runStderr { onStandardErrorLine?(line) }
        return ScriptProcessResult(exitCode: runExit, standardOutput: runStdout,
                                   standardError: runStderr.joined(separator: "\n"))
    }
}

@MainActor
@Suite("ScriptRunController")
struct ScriptRunControllerTests {

    private func makeController(_ executor: FakeExecutor,
                               input: URL? = URL(fileURLWithPath: "/in/model.usdz"),
                               onReimport: @escaping (URL) async -> Void = { _ in })
    -> ScriptRunController {
        ScriptRunController(
            entry: ScriptEntry(url: URL(fileURLWithPath: "/s/rename.py"), isBundled: true),
            inputURL: input, executor: executor, onReimport: onReimport)
    }

    @Test func loadsManifestAndSeedsDefaults() async {
        let executor = FakeExecutor(manifestJSON: """
        {"name":"Batch Rename","mutates":true,
         "args":[{"name":"pattern","type":"str","default":"^(.*)$"},
                 {"name":"lower","type":"bool","default":false}]}
        """)
        let controller = makeController(executor)
        await controller.loadManifest()

        #expect(controller.phase == .ready)
        #expect(controller.manifest?.name == "Batch Rename")
        #expect(controller.argumentValues["pattern"] == "^(.*)$")
        #expect(controller.argumentValues["lower"] == "false")
        #expect(controller.canRun)
    }

    @Test func runStreamsProgressAndReimports() async {
        let executor = FakeExecutor(
            manifestJSON: #"{"name":"R","mutates":true}"#,
            runStderr: ["[  0%] start", "renamed 2", "[100%] done"],
            runStdout: "")
        let box = ReimportBox()
        let controller = makeController(executor, onReimport: { await box.set($0) })

        await controller.loadManifest()
        await controller.run()

        #expect(controller.phase == .succeeded(reimported: true))
        #expect(controller.progressFraction == 1)
        #expect(controller.logLines.contains("renamed 2"))
        #expect(await box.value != nil)      // a produced file was handed back
    }

    @Test func nonMutatingRunDoesNotReimport() async {
        let executor = FakeExecutor(
            manifestJSON: #"{"name":"Audit","mutates":false}"#,
            runStdout: "3 issues found")
        let box = ReimportBox()
        let controller = makeController(executor, onReimport: { await box.set($0) })

        await controller.loadManifest()
        await controller.run()

        #expect(controller.phase == .succeeded(reimported: false))
        #expect(await box.value == nil)
        #expect(controller.logLines.contains("3 issues found"))
    }

    @Test func failedRunSurfacesMessage() async {
        let executor = FakeExecutor(
            manifestJSON: #"{"name":"R","mutates":true}"#,
            runStderr: ["Traceback", "ValueError: bad"],
            runExit: 1)
        let controller = makeController(executor)
        await controller.loadManifest()
        await controller.run()

        if case .failed = controller.phase {} else {
            Issue.record("expected failed phase, got \(controller.phase)")
        }
    }

    @Test func mutatingScriptBlocksRunWithNoDocument() async {
        let executor = FakeExecutor(manifestJSON: #"{"name":"R","mutates":true}"#)
        let controller = makeController(executor, input: nil)
        await controller.loadManifest()
        #expect(!controller.canRun)   // mutating + no file + not dry-run
    }
}

private actor ReimportBox {
    private(set) var value: URL?
    func set(_ url: URL) { value = url }
}
