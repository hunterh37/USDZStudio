import Testing
import Foundation
@testable import ScriptingKit

/// In-memory `ScriptExecuting` fake for the console: records each program path
/// it was handed and returns a scripted result (or throws to simulate a launch
/// failure).
private final class ConsoleExecutor: ScriptExecuting, @unchecked Sendable {
    var stdout = ""
    var stderr = ""
    var exitCode: Int32 = 0
    var launchError: Error?
    private(set) var invocations: [String] = []

    func execute(scriptPath: String, arguments: [String],
                 onStandardErrorLine: (@Sendable (String) -> Void)?) async throws -> ScriptProcessResult {
        if let launchError { throw launchError }
        invocations.append(scriptPath)
        return ScriptProcessResult(exitCode: exitCode, standardOutput: stdout, standardError: stderr)
    }
}

private struct BoomError: Error {}

private func session(_ executor: ConsoleExecutor,
                     context: ReplContext = ReplContext(inputPath: "/tmp/model.usda"),
                     captured: (@Sendable (String) -> Void)? = nil) -> ReplSession {
    ReplSession(executor: executor, context: context, writeProgram: { program in
        captured?(program)
        return URL(fileURLWithPath: "/tmp/console-\(program.count).py")
    })
}

// MARK: - ReplProgram

@Test func programInjectsNamesAndWrapsUserCodeOnce() {
    let context = ReplContext(inputPath: "/a/b.usdz", selection: ["/Root/Mesh"])
    let program = ReplProgram.source(userCode: "print(len(selection))", context: context)

    #expect(program.contains(ReplProgram.injectionBanner))
    // The user code appears exactly once, after the single user-code banner.
    #expect(program.components(separatedBy: ReplProgram.userCodeBanner).count == 2)
    #expect(program.contains("Usd.Stage.Open(\"/a/b.usdz\")"))
    #expect(program.contains("[stage.GetPrimAtPath(p) for p in [\"/Root/Mesh\"]]"))
    #expect(program.contains("print(len(selection))"))
}

@Test func pythonStringEscapesSpecialCharacters() {
    let escaped = ReplProgram.pythonString("a\\b\"c\nd\re\tf")
    #expect(escaped == "\"a\\\\b\\\"c\\nd\\re\\tf\"")
}

@Test func pythonListEmptyAndMulti() {
    #expect(ReplProgram.pythonList([]) == "[]")
    #expect(ReplProgram.pythonList(["/x", "/y"]) == "[\"/x\", \"/y\"]")
}

// MARK: - ReplInputClassifier

@Test func classifierCompleteSimpleStatement() {
    #expect(!ReplInputClassifier.needsMoreInput("x = 1"))
}

@Test func classifierBackslashContinuation() {
    #expect(ReplInputClassifier.needsMoreInput("x = 1 + \\"))
}

@Test func classifierUnbalancedBrackets() {
    #expect(ReplInputClassifier.needsMoreInput("foo([1, 2"))
    #expect(!ReplInputClassifier.needsMoreInput("foo([1, 2])"))
}

@Test func classifierIgnoresBracketsAndColonInStrings() {
    // The colon and open-paren live inside a string, so this is complete.
    #expect(!ReplInputClassifier.needsMoreInput("x = 'a:( '"))
    // Escaped quote inside a string does not end the string early.
    #expect(!ReplInputClassifier.needsMoreInput("x = 'a\\'b'"))
}

@Test func classifierCompoundStatementNeedsBlankLine() {
    #expect(ReplInputClassifier.needsMoreInput("if True:"))
    #expect(ReplInputClassifier.needsMoreInput("if True:\n    x = 1"))
    #expect(!ReplInputClassifier.needsMoreInput("if True:\n    x = 1\n"))
}

@Test func classifierMultiLineNonBlockIsComplete() {
    // Two simple statements across a newline (no block header) are complete.
    #expect(!ReplInputClassifier.needsMoreInput("x = 1\ny = 2\n"))
}

@Test func classifierClosingExtraBracketDoesNotUnderflow() {
    // A stray closing bracket must not drive depth negative.
    #expect(!ReplInputClassifier.needsMoreInput("x = 1)"))
}

// MARK: - ReplHistory

@Test func historyRecordsAndSkipsEmptyAndDuplicates() {
    var history = ReplHistory()
    history.record("a")
    history.record("a")          // duplicate of last — skipped
    history.record("   \n ")     // empty — skipped
    history.record("b")
    #expect(history.entries == ["a", "b"])
}

@Test func historyNavigation() {
    var history = ReplHistory()
    history.record("first")
    history.record("second")

    #expect(history.previous() == "second")
    #expect(history.previous() == "first")
    #expect(history.previous() == nil)      // at oldest
    #expect(history.next() == "second")
    #expect(history.next() == nil)          // past newest → empty draft
}

@Test func historyNextWhenNotBrowsingReturnsNil() {
    var history = ReplHistory()
    history.record("only")
    #expect(history.next() == nil)
}

// MARK: - ReplSession

@Test func sessionEvaluatesCompleteSubmissionAsOneRun() async {
    let executor = ConsoleExecutor()
    executor.stdout = "3\n"
    let sut = session(executor)

    let outcome = await sut.submit(line: "print(1 + 2)")
    guard case .evaluated(let entry) = outcome else {
        Issue.record("expected evaluated"); return
    }
    #expect(entry.output == "3\n")
    #expect(!entry.isError)
    #expect(executor.invocations.count == 1)          // single-undo: one run
    let transcript = await sut.transcript
    #expect(transcript == [entry])
}

@Test func sessionBuffersMultiLineSubmission() async {
    let executor = ConsoleExecutor()
    let sut = session(executor)

    #expect(await sut.submit(line: "if True:") == .needsMore)
    var pending = await sut.pendingSource()
    #expect(pending == "if True:")
    #expect(await sut.submit(line: "    x = 1") == .needsMore)
    let final = await sut.submit(line: "")     // blank line completes the block
    guard case .evaluated = final else { Issue.record("expected evaluated"); return }
    #expect(executor.invocations.count == 1)
    pending = await sut.pendingSource()
    #expect(pending == "")                     // buffer cleared after evaluation
}

@Test func sessionReportsNonZeroExitAsError() async {
    let executor = ConsoleExecutor()
    executor.exitCode = 1
    executor.stderr = "Traceback: NameError"
    let sut = session(executor)

    let outcome = await sut.submit(line: "boom")
    guard case .evaluated(let entry) = outcome else {
        Issue.record("expected evaluated"); return
    }
    #expect(entry.isError)
    #expect(entry.diagnostics == "Traceback: NameError")
}

@Test func sessionReportsLaunchFailureAsError() async {
    let executor = ConsoleExecutor()
    executor.launchError = BoomError()
    let sut = session(executor)

    let outcome = await sut.submit(line: "x = 1")
    guard case .evaluated(let entry) = outcome else {
        Issue.record("expected evaluated"); return
    }
    #expect(entry.isError)
    #expect(entry.output.isEmpty)
    #expect(entry.diagnostics.contains("BoomError"))
}

@Test func sessionForwardsContextAndCapturesProgram() async {
    let executor = ConsoleExecutor()
    let box = ProgramBox()
    let sut = ReplSession(
        executor: executor,
        context: ReplContext(inputPath: "/scene.usda", selection: ["/S"]),
        writeProgram: { program in box.value = program; return URL(fileURLWithPath: "/tmp/c.py") })

    _ = await sut.submit(line: "app.log('hi')")
    #expect(box.value?.contains("Usd.Stage.Open(\"/scene.usda\")") == true)
    #expect(box.value?.contains("app.log('hi')") == true)
}

@Test func sessionHistoryRecallAcrossSubmissions() async {
    let executor = ConsoleExecutor()
    let sut = session(executor)
    _ = await sut.submit(line: "one")
    _ = await sut.submit(line: "two")

    #expect(await sut.recallPrevious() == "two")
    #expect(await sut.recallPrevious() == "one")
    #expect(await sut.recallNext() == "two")
}

@Test func defaultProgramWriterWritesFile() throws {
    let url = ReplSession.defaultProgramWriter("print('written')")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("print('written')"))
    #expect(url.pathExtension == "py")
}

/// Reference box so the `@Sendable` writeProgram closure can hand a captured
/// program back out of the actor for assertions.
private final class ProgramBox: @unchecked Sendable {
    var value: String?
}
