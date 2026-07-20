import Testing
import Foundation
import USDCore
import ScriptingKit
@testable import EditorUI

/// Canned interpreter: returns a fixed exit/stdout/stderr for every run, so the
/// console controller is driven with no Python.
private final class ConsoleExecutor: ScriptExecuting, @unchecked Sendable {
    let exit: Int32
    let stdout: String
    let stderr: String
    init(exit: Int32 = 0, stdout: String = "ok", stderr: String = "") {
        self.exit = exit
        self.stdout = stdout
        self.stderr = stderr
    }
    func execute(scriptPath: String, arguments: [String],
                 onStandardErrorLine: (@Sendable (String) -> Void)?) async throws -> ScriptProcessResult {
        ScriptProcessResult(exitCode: exit, standardOutput: stdout, standardError: stderr)
    }
}

/// Records file writes and serves a scripted read result (or error), off the
/// main actor, matching the controller's `@Sendable` snapshot seams.
private actor IOHarness {
    private(set) var writes = 0
    private var readResult: StageSnapshot
    private var writeError: Error?
    private var readError: Error?

    init(readResult: StageSnapshot) { self.readResult = readResult }
    func setWriteError(_ e: Error?) { writeError = e }
    func setReadError(_ e: Error?) { readError = e }
    func writeCount() -> Int { writes }

    func write(_ snapshot: StageSnapshot, _ url: URL) throws {
        if let writeError { throw writeError }
        writes += 1
    }
    func read(_ url: URL) throws -> StageSnapshot {
        if let readError { throw readError }
        return readResult
    }
}

private struct DummyError: Error {}

@MainActor
@Suite("ReplController")
struct ReplControllerTests {

    private final class Commits { var calls: [(StageSnapshot, String)] = [] }

    private func makeController(
        executor: ConsoleExecutor,
        harness: IOHarness,
        commits: Commits,
        live: StageSnapshot = StageSnapshot()
    ) -> ReplController {
        let session = ReplSession(
            executor: executor,
            context: ReplContext(inputPath: "/tmp/working.usda"),
            writeProgram: { _ in URL(fileURLWithPath: "/tmp/console.py") })
        return ReplController(
            session: session,
            workingURL: URL(fileURLWithPath: "/tmp/working.usda"),
            liveSnapshot: { live },
            writeSnapshot: { snap, url in try await harness.write(snap, url) },
            readSnapshot: { url in try await harness.read(url) },
            commit: { after, label in commits.calls.append((after, label)) })
    }

    private func changed() -> StageSnapshot {
        StageSnapshot(rootPrims: [Prim(path: PrimPath("/New")!, typeName: "Xform")])
    }

    @Test func evaluatedSubmissionAppendsTranscriptAndCommits() async {
        let harness = IOHarness(readResult: changed())
        let commits = Commits()
        let controller = makeController(executor: ConsoleExecutor(stdout: "hi"),
                                        harness: harness, commits: commits)
        await controller.submit(line: "print('hi')")

        #expect(controller.transcript.count == 1)
        #expect(controller.transcript.first?.entry.output == "hi")
        #expect(controller.isRunning == false)
        #expect(controller.needsContinuation == false)
        #expect(commits.calls.count == 1)
        #expect(commits.calls.first?.1 == "Console: print('hi')")
        #expect(await harness.writeCount() == 1)
    }

    @Test func multiLineSubmissionBuffersThenRuns() async {
        let harness = IOHarness(readResult: changed())
        let commits = Commits()
        let controller = makeController(executor: ConsoleExecutor(),
                                        harness: harness, commits: commits)

        await controller.submit(line: "def f():")
        #expect(controller.needsContinuation == true)
        #expect(controller.pending == "def f():")
        #expect(controller.transcript.isEmpty)
        #expect(commits.calls.isEmpty)

        await controller.submit(line: "    return 1")
        #expect(controller.needsContinuation == true)

        await controller.submit(line: "")   // blank line completes the block
        #expect(controller.needsContinuation == false)
        #expect(controller.pending == "")
        #expect(controller.transcript.count == 1)
        #expect(commits.calls.count == 1)
        #expect(commits.calls.first?.1 == "Console: def f():")
    }

    @Test func erroringSubmissionDoesNotCommit() async {
        let harness = IOHarness(readResult: changed())
        let commits = Commits()
        let controller = makeController(
            executor: ConsoleExecutor(exit: 1, stdout: "", stderr: "Traceback"),
            harness: harness, commits: commits)
        await controller.submit(line: "boom(")   // completes? '(' unbalanced → needsMore

        // The open paren buffers; close it on the next line to actually run.
        await controller.submit(line: ")")
        #expect(controller.transcript.count == 1)
        #expect(controller.transcript.first?.entry.isError == true)
        #expect(commits.calls.isEmpty)
    }

    @Test func writeFailureAbortsBeforeRunning() async {
        let harness = IOHarness(readResult: changed())
        await harness.setWriteError(DummyError())
        let commits = Commits()
        let controller = makeController(executor: ConsoleExecutor(),
                                        harness: harness, commits: commits)
        await controller.submit(line: "print(1)")

        #expect(controller.transcript.isEmpty)
        #expect(commits.calls.isEmpty)
        #expect(controller.ioError != nil)
        #expect(controller.isRunning == false)
    }

    @Test func readFailureSurfacesButKeepsTranscript() async {
        let harness = IOHarness(readResult: changed())
        await harness.setReadError(DummyError())
        let commits = Commits()
        let controller = makeController(executor: ConsoleExecutor(),
                                        harness: harness, commits: commits)
        await controller.submit(line: "print(1)")

        #expect(controller.transcript.count == 1)
        #expect(commits.calls.isEmpty)
        #expect(controller.ioError != nil)
    }

    @Test func labelTruncatesAndFallsBack() {
        let harness = IOHarness(readResult: changed())
        let controller = makeController(executor: ConsoleExecutor(),
                                        harness: harness, commits: Commits())
        let long = String(repeating: "x", count: 80)
        #expect(controller.label(for: long).hasSuffix("…"))
        #expect(controller.label(for: "\n\n").hasPrefix("Console"))
        #expect(controller.label(for: "") == "Console")
        #expect(controller.label(for: "a = 1\nb = 2") == "Console: a = 1")
    }

    @Test func historyRecallDelegatesToSession() async {
        let harness = IOHarness(readResult: changed())
        let controller = makeController(executor: ConsoleExecutor(),
                                        harness: harness, commits: Commits())
        await controller.submit(line: "first")
        await controller.submit(line: "second")
        #expect(await controller.recallPrevious() == "second")
        #expect(await controller.recallPrevious() == "first")
        #expect(await controller.recallNext() == "second")
    }
}
