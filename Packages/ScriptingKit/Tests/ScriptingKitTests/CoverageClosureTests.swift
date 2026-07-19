import Testing
import Foundation
@testable import ScriptingKit

/// In-memory executor returning a canned result.
private final class StubExecutor: ScriptExecuting, @unchecked Sendable {
    var exitCode: Int32 = 0
    var stdout = ""
    var stderr = ""
    func execute(scriptPath: String, arguments: [String],
                 onStandardErrorLine: (@Sendable (String) -> Void)?) async throws -> ScriptProcessResult {
        ScriptProcessResult(exitCode: exitCode, standardOutput: stdout, standardError: stderr)
    }
}

@Suite("ScriptingKit coverage closure")
struct ScriptingKitCoverageClosureTests {

    @Test func loadManifestThrowsOnNonZeroExit() async {
        let exec = StubExecutor()
        exec.exitCode = 3
        exec.stderr = "boom"
        let runner = ScriptRunner(executor: exec, makeTemporaryOutput: { $0 })
        await #expect(throws: ScriptRunError.self) {
            try await runner.loadManifest(script: URL(fileURLWithPath: "/s/x.py"))
        }
    }

    @Test func defaultTemporaryOutputPreservesBasenameAndExtension() {
        let out = ScriptRunner.defaultTemporaryOutput(URL(fileURLWithPath: "/in/model.usdz"))
        #expect(out.lastPathComponent == "model-scripted.usdz")
        #expect(out.deletingLastPathComponent().lastPathComponent.hasPrefix("dicyanin-script-"))
    }

    @Test func defaultTemporaryOutputDefaultsExtensionWhenMissing() {
        let out = ScriptRunner.defaultTemporaryOutput(URL(fileURLWithPath: "/in/model"))
        #expect(out.lastPathComponent == "model-scripted.usda")
    }

    @Test func manifestDecodesDoubleArgumentDefault() throws {
        let json = Data(#"{"name":"Scale","args":[{"name":"amount","type":"float","default":1.5}]}"#.utf8)
        let manifest = try ScriptManifest.decode(fromJSON: json)
        #expect(manifest.argument(named: "amount")?.defaultValue == .double(1.5))
    }
}
