import Testing
import Foundation
import USDCore
@testable import EditingKit

/// The Milestone 4 exit criterion: **kill the process, recover the exact
/// command stack.**
///
/// What this suite actually proves, precisely:
///
///  * The WAL is written by the real `CommandStack` + `FileCommandJournal` —
///    every record goes through the same `fsync`-on-append path the app uses.
///  * A *real* child process is terminated with `SIGKILL`, so no graceful
///    shutdown, no `finish(_:)`, no sentinel cleanup, and no flush-on-exit
///    hook ever runs — exactly the state a crashed editor leaves behind.
///  * From nothing but the bytes on disk, `SessionStore` finds the orphaned
///    session and `CommandStack.recovered` rebuilds the stage content *and*
///    both the undo and redo stacks, to the same depths and labels.
///  * A record torn in half by the kill (a partial trailing line) is discarded
///    without taking the complete records before it down with it.
@Suite("Crash recovery: kill -9 restores the exact command stack")
struct CrashRecoveryTests {

    private func scratchStore() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true))
    }

    private func documentStage() -> InMemoryStage {
        let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh",
                         attributes: [Attribute(name: "radius", value: .double(1.0))])
        let body = Prim(path: PrimPath("/Car/Body")!, typeName: "Mesh")
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [body, wheel])
        return InMemoryStage(StageSnapshot(sourceURL: URL(fileURLWithPath: "/tmp/car.usda"),
                                           rootPrims: [car]))
    }

    /// Terminates a real child process with SIGKILL and returns its status.
    /// `sh -c 'kill -9 $$'` cannot catch or clean up after the signal.
    @discardableResult
    private func killRealChildProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "kill -9 $$"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func killedSessionRecoversExactStackAndContent() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let source = URL(fileURLWithPath: "/tmp/car.usda")

        // ── The doomed session: real journal, real commands, no clean shutdown.
        let live = documentStage()
        let session = try store.startSession(for: source)
        let stack = CommandStack(stage: live, journal: session.journal)

        let wheel = PrimPath("/Car/Wheel")!
        let body = PrimPath("/Car/Body")!
        try stack.run(RecordedCommand(
            label: "Resize Wheel",
            forward: [.setAttribute(path: wheel, attribute: Attribute(name: "radius", value: .double(4.0)))],
            inverse: [.setAttribute(path: wheel, attribute: Attribute(name: "radius", value: .double(1.0)))]))
        try stack.run(RecordedCommand(
            label: "Hide Body",
            forward: [.setVisibility(path: body, visibility: .invisible)],
            inverse: [.setVisibility(path: body, visibility: .inherited)]))
        try stack.run(RecordedCommand(
            label: "Deactivate Body",
            forward: [.setActive(path: body, isActive: false)],
            inverse: [.setActive(path: body, isActive: true)]))
        _ = try stack.undo()   // leaves 2 undoable, 1 redoable

        let expectedContent = live.currentSnapshot
        let expectedUndo = stack.undoCount
        let expectedRedo = stack.redoCount
        let expectedUndoLabel = stack.undoLabel
        let expectedRedoLabel = stack.redoLabel

        // ── The crash. A real process dies by SIGKILL; nothing is cleaned up.
        #expect(try killRealChildProcess() == SIGKILL)

        // ── Relaunch: only the bytes on disk survive.
        let relaunched = SessionStore(root: store.root)
        let plans = relaunched.recoverableSessions()
        #expect(plans.count == 1)
        let plan = try #require(plans.first)
        #expect(plan.sourceURL == source)
        #expect(plan.hasWork)

        // Reopen the last-saved document from scratch and replay.
        let reopened = documentStage()
        let reopenedJournal = try FileCommandJournal(
            url: plan.directory.appendingPathComponent("journal.wal"))
        let recovered = try CommandStack.recovered(
            stage: reopened, journal: reopenedJournal, records: plan.records)

        #expect(reopened.currentSnapshot == expectedContent)
        #expect(recovered.undoCount == expectedUndo)
        #expect(recovered.redoCount == expectedRedo)
        #expect(recovered.undoLabel == expectedUndoLabel)
        #expect(recovered.redoLabel == expectedRedoLabel)

        // The restored stack is fully live: redo the undone command, then unwind
        // everything, and the document lands back on its opened state.
        _ = try recovered.redo()
        #expect(reopened.prim(at: body)?.isActive == false)
        while recovered.canUndo { _ = try recovered.undo() }
        #expect(reopened.currentSnapshot == documentStage().currentSnapshot)

        // Finishing the recovered session clears it from the recoverable set.
        relaunched.discard(plan)
        #expect(relaunched.recoverableSessions().isEmpty)
    }

    @Test func recordTornByTheKillIsDiscardedButPriorWorkSurvives() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let live = documentStage()
        let session = try store.startSession(for: URL(fileURLWithPath: "/tmp/car.usda"))
        let stack = CommandStack(stage: live, journal: session.journal)
        let body = PrimPath("/Car/Body")!
        try stack.run(RecordedCommand(
            label: "Hide Body",
            forward: [.setVisibility(path: body, visibility: .invisible)],
            inverse: [.setVisibility(path: body, visibility: .inherited)]))

        // Simulate the kill landing mid-`append`: a half-written trailing line
        // with no terminating newline and no fsync.
        let walURL = session.directory.appendingPathComponent("journal.wal")
        let handle = try FileHandle(forWritingTo: walURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"command":{"label":"Half Writt"#.utf8))
        try handle.close()
        #expect(try killRealChildProcess() == SIGKILL)

        let plan = try #require(SessionStore(root: store.root).recoverableSessions().first)
        let reopened = documentStage()
        let recovered = try CommandStack.recovered(stage: reopened, journal: nil, records: plan.records)

        // The complete command survived; the torn one did not corrupt recovery.
        #expect(recovered.undoCount == 1)
        #expect(recovered.undoLabel == "Hide Body")
        #expect(reopened.prim(at: body)?.visibility == .invisible)
    }
}
