import Testing
import SwiftUI
import Foundation
import USDCore
import ScriptingKit
@testable import EditorUI

/// Canned interpreter so the console panel can be built with a live controller,
/// no Python involved (mirrors ReplControllerTests' harness).
private final class CannedExecutor: ScriptExecuting, @unchecked Sendable {
    let exit: Int32
    let stdout: String
    let stderr: String
    init(exit: Int32 = 0, stdout: String = "ok", stderr: String = "") {
        self.exit = exit; self.stdout = stdout; self.stderr = stderr
    }
    func execute(scriptPath: String, arguments: [String],
                 onStandardErrorLine: (@Sendable (String) -> Void)?) async throws -> ScriptProcessResult {
        ScriptProcessResult(exitCode: exit, standardOutput: stdout, standardError: stderr)
    }
}

@MainActor
@Suite struct ConsolePanelViewTests {

    private func makeController(executor: CannedExecutor) -> ReplController {
        let session = ReplSession(
            executor: executor,
            context: ReplContext(inputPath: "/tmp/working.usda"),
            writeProgram: { _ in URL(fileURLWithPath: "/tmp/console.py") })
        let live = StageSnapshot(rootPrims: [Prim(path: PrimPath("/New")!, typeName: "Xform")])
        return ReplController(
            session: session,
            workingURL: URL(fileURLWithPath: "/tmp/working.usda"),
            liveSnapshot: { live },
            writeSnapshot: { _, _ in },
            readSnapshot: { _ in live },
            commit: { _, _ in })
    }

    @Test func consolePanelEmptyTranscript() {
        let controller = makeController(executor: CannedExecutor())
        _ = ConsolePanel(controller: controller, onClose: {}).body
    }

    @Test func consolePanelPopulatedTranscriptAndError() async {
        // A successful line populates the transcript (output branch).
        let ok = makeController(executor: CannedExecutor(stdout: "hi"))
        await ok.submit(line: "print('hi')")
        _ = ConsolePanel(controller: ok, onClose: {}).body

        // An erroring line populates the diagnostics/error branch.
        let bad = makeController(executor: CannedExecutor(exit: 1, stdout: "", stderr: "Traceback"))
        await bad.submit(line: "boom()")
        _ = ConsolePanel(controller: bad, onClose: {}).body
    }
}
