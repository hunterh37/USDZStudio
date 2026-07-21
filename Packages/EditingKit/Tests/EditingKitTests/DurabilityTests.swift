import Testing
import Foundation
import USDCore
@testable import EditingKit

// A stage rich enough to exercise every StageMutation inverse:
//   /Car (Xform, variantSet color={red,blue} sel=red)
//     /Body (Mesh)
//     /Wheel (Mesh, radius=1.0, visible, active)
private func richStage() -> InMemoryStage {
    let wheel = Prim(
        path: PrimPath("/Car/Wheel")!, typeName: "Mesh",
        attributes: [Attribute(name: "radius", value: .double(1.0))])
    let body = Prim(path: PrimPath("/Car/Body")!, typeName: "Mesh")
    let car = Prim(
        path: PrimPath("/Car")!, typeName: "Xform",
        variantSets: [VariantSet(name: "color", variants: ["red", "blue"], selection: "red")],
        children: [body, wheel])
    return InMemoryStage(StageSnapshot(sourceURL: URL(fileURLWithPath: "/tmp/car.usda"),
                                       rootPrims: [car]))
}

private let wheelPath = PrimPath("/Car/Wheel")!
private let bodyPath = PrimPath("/Car/Body")!
private let carPath = PrimPath("/Car")!

/// Wraps a forward mutation list as a command so the journaling proxy captures
/// and inverts it — `inverse` here is ignored on the journaled path.
private func cmd(_ label: String, _ forward: [StageMutation]) -> RecordedCommand {
    RecordedCommand(label: label, forward: forward, inverse: [])
}

/// Runs a single-mutation command whose inverse is computed against the stage's
/// *current* state — so in-session undo works exactly like a hand-written
/// command. (The journaled path recomputes the same inverse via the proxy.)
@discardableResult
private func apply(_ stack: CommandStack, on stage: InMemoryStage,
                   _ label: String, _ mutation: StageMutation) throws -> String {
    let inverse = mutation.inverse(reading: stage)!
    return try stack.run(RecordedCommand(label: label, forward: [mutation], inverse: [inverse]))
}

@Suite("JournalRecord + FileCommandJournal")
struct CommandJournalTests {

    @Test func inMemoryRoundTrips() throws {
        let j = InMemoryCommandJournal()
        try j.append(.checkpoint(sourceURL: URL(fileURLWithPath: "/a.usda")))
        try j.append(.undo)
        #expect(try j.readAll().count == 2)
        try j.reset()
        #expect(try j.readAll().isEmpty)
    }

    @Test func fileJournalPersistsAndReopens() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.wal")

        let j = try FileCommandJournal(url: url)
        try j.append(.checkpoint(sourceURL: nil))
        try j.append(.command(label: "X",
                              forward: [.setActive(path: bodyPath, isActive: false)],
                              inverse: [.setActive(path: bodyPath, isActive: true)]))
        // Reopen a second handle over the same file — records survive.
        let reopened = try FileCommandJournal(url: url)
        let all = try reopened.readAll()
        #expect(all.count == 2)
        if case .command(let label, _, _) = all[1] { #expect(label == "X") } else { Issue.record("bad") }

        try reopened.reset()
        #expect(try reopened.readAll().isEmpty)
    }

    @Test func emptyFileReadsAsNoRecords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wal")
        defer { try? FileManager.default.removeItem(at: url) }
        let j = try FileCommandJournal(url: url)
        #expect(try j.readAll().isEmpty)
    }

    @Test func tornFinalRecordIsDiscarded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wal")
        defer { try? FileManager.default.removeItem(at: url) }
        let j = try FileCommandJournal(url: url)
        try j.append(.undo)                       // one complete, newline-terminated record
        // Simulate a crash mid-append: a partial line with no trailing newline.
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"partial":"#.utf8))
        try h.close()

        let all = try j.readAll()
        #expect(all == [.undo])                   // torn tail dropped, good record kept
    }
}

@Suite("CommandStack journaling + crash recovery")
struct CommandStackRecoveryTests {

    /// Drives a journaled stack through every mutation kind plus undo/redo, then
    /// replays the WAL onto a fresh stage and asserts byte-for-byte parity of
    /// both the stage content and the undo/redo stacks.
    @Test func replayRestoresExactStackAndContent() throws {
        let a = richStage()
        let journal = InMemoryCommandJournal()
        let stackA = CommandStack(stage: a, journal: journal)

        try apply(stackA, on: a, "Resize", .setAttribute(path: wheelPath,
            attribute: Attribute(name: "radius", value: .double(2.0))))          // existing attr
        try apply(stackA, on: a, "Tag", .setAttribute(path: wheelPath,
            attribute: Attribute(name: "tag", value: .string("hi"))))            // new attr
        try apply(stackA, on: a, "Hide", .setVisibility(path: bodyPath, visibility: .invisible))
        try apply(stackA, on: a, "Deactivate", .setActive(path: bodyPath, isActive: false))
        try apply(stackA, on: a, "Rename", .renamePrim(path: wheelPath, newName: "Tire"))
        try apply(stackA, on: a, "DropTag", .removeAttribute(path: PrimPath("/Car/Tire")!, name: "tag"))
        try apply(stackA, on: a, "Delete", .removePrim(path: bodyPath))
        let newPrim = Prim(path: PrimPath("/Car/Axle")!, typeName: "Xform")
        try apply(stackA, on: a, "Add", .insertPrim(parent: carPath, index: 0, prim: newPrim))
        try apply(stackA, on: a, "Meta", .setStageMetadata(StageMetadata(upAxis: .z, metersPerUnit: 0.01)))
        try apply(stackA, on: a, "Variant", .setVariantSelection(path: carPath, setName: "color", selection: "blue"))
        // Exercise undo + redo markers.
        _ = try stackA.undo()   // undo Variant
        _ = try stackA.undo()   // undo Meta
        _ = try stackA.redo()   // redo Meta

        let contentA = a.currentSnapshot
        let (undoA, redoA) = (stackA.undoCount, stackA.redoCount)

        // Recover onto a pristine, identical stage using only the WAL.
        let tail = SessionStore.plan(
            for: URL(fileURLWithPath: "/x"), records: try journal.readAll()).records
        let b = richStage()
        let stackB = try CommandStack.recovered(stage: b, journal: nil, records: tail)

        #expect(b.currentSnapshot == contentA)
        #expect(stackB.undoCount == undoA)
        #expect(stackB.redoCount == redoA)

        // And the recovered stacks keep unwinding identically to the original.
        while stackB.canUndo {
            #expect(try stackB.undo() == (try stackA.undo()))
            #expect(b.currentSnapshot == a.currentSnapshot)
        }
        #expect(b.currentSnapshot == a.currentSnapshot)
    }

    @Test func nonJournaledStackSkipsWAL() throws {
        let a = richStage()
        let stack = CommandStack(stage: a)   // no journal
        let c = RecordedCommand(
            label: "Hide",
            forward: [.setVisibility(path: bodyPath, visibility: .invisible)],
            inverse: [.setVisibility(path: bodyPath, visibility: .inherited)])
        try stack.run(c)
        #expect(a.prim(at: bodyPath)?.visibility == .invisible)
        _ = try stack.undo()                 // RecordedCommand.undo (reversed inverse)
        #expect(a.prim(at: bodyPath)?.visibility == .inherited)
        _ = try stack.redo()
        #expect(a.prim(at: bodyPath)?.visibility == .invisible)
    }

    @Test func failedCommandDoesNotJournalOrPush() throws {
        let a = richStage()
        let journal = InMemoryCommandJournal()
        let stack = CommandStack(stage: a, journal: journal)
        #expect(throws: StageMutationError.self) {
            try stack.run(cmd("Bad", [.setVisibility(path: PrimPath("/Ghost")!, visibility: .invisible)]))
        }
        #expect(stack.undoCount == 0)
        // Only the opening checkpoint was written.
        #expect(try journal.readAll().count == 1)
    }

    @Test func clearResetsWALWithCheckpoint() throws {
        let a = richStage()
        let journal = InMemoryCommandJournal()
        let stack = CommandStack(stage: a, journal: journal)
        try stack.run(cmd("Hide", [.setVisibility(path: bodyPath, visibility: .invisible)]))
        stack.clear()
        #expect(stack.canUndo == false)
        let all = try journal.readAll()
        #expect(all.count == 1)                       // reset + fresh checkpoint
        if case .checkpoint = all[0] {} else { Issue.record("expected checkpoint") }
    }

    @Test func recoverToleratesMarkersAndMidCheckpoint() throws {
        // Unmatched undo/redo are ignored; a mid-stream checkpoint resets history.
        let a = richStage()
        let records: [JournalRecord] = [
            .undo,                                     // nothing to undo — ignored
            .redo,                                     // nothing to redo — ignored
            .command(label: "Hide",
                     forward: [.setVisibility(path: bodyPath, visibility: .invisible)],
                     inverse: [.setVisibility(path: bodyPath, visibility: .inherited)]),
            .checkpoint(sourceURL: nil),               // resets the stack
        ]
        let stack = try CommandStack.recovered(stage: a, journal: nil, records: records)
        #expect(stack.canUndo == false)
        #expect(a.prim(at: bodyPath)?.visibility == .invisible)  // content change stays
    }

    @Test func inverseOfRemovingAbsentAttributeIsANoOpRemoval() throws {
        // Removing an attribute that isn't there is idempotent, so its inverse
        // is the same removal — recovery must still round-trip cleanly.
        let a = richStage()
        let journal = InMemoryCommandJournal()
        let stack = CommandStack(stage: a, journal: journal)
        try stack.run(cmd("DropMissing", [.removeAttribute(path: wheelPath, name: "ghostAttr")]))

        let tail = SessionStore.plan(
            for: URL(fileURLWithPath: "/x"), records: try journal.readAll()).records
        let b = richStage()
        _ = try CommandStack.recovered(stage: b, journal: nil, records: tail)
        #expect(b.currentSnapshot == a.currentSnapshot)
    }

    @Test func onChangeFiresThroughProxy() throws {
        let a = richStage()
        let journal = InMemoryCommandJournal()
        let stack = CommandStack(stage: a, journal: journal)
        let count = Counter()
        stack.onChange = { count.bump() }
        try stack.run(cmd("Hide", [.setVisibility(path: bodyPath, visibility: .invisible)]))
        _ = try stack.undo()
        _ = try stack.redo()
        #expect(count.value >= 3)
        // Proxy getters are pure passthrough.
        let proxy = JournalingStage(a)
        #expect(proxy.sourceURL == a.sourceURL)
        #expect(proxy.metadata == a.metadata)
        #expect(proxy.rootPrims == a.rootPrims)
    }
}

@Suite("SessionStore autosave recovery")
struct SessionStoreTests {

    private func tempStore() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    @Test func crashedSessionIsRecoverable() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let src = URL(fileURLWithPath: "/tmp/model.usda")
        let session = try store.startSession(for: src)
        // Sentinel + journal exist.
        #expect(FileManager.default.fileExists(atPath: session.sentinel.path))
        try session.journal.append(.checkpoint(sourceURL: src))
        try session.journal.append(.command(label: "Hide",
            forward: [.setVisibility(path: bodyPath, visibility: .invisible)],
            inverse: [.setVisibility(path: bodyPath, visibility: .inherited)]))

        // Simulate relaunch: a new store over the same root finds the session.
        let plans = store.recoverableSessions()
        #expect(plans.count == 1)
        let plan = try #require(plans.first)
        #expect(plan.sourceURL == src)
        #expect(plan.hasWork)
        #expect(plan.records.count == 1)               // checkpoint stripped

        // A clean finish removes it from the recoverable set.
        store.finish(session)
        #expect(store.recoverableSessions().isEmpty)
    }

    @Test func emptyJournalSessionIsSweptNotOffered() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let session = try store.startSession(for: nil)   // never written to
        #expect(store.recoverableSessions().isEmpty)     // swept because WAL empty
        #expect(FileManager.default.fileExists(atPath: session.directory.path) == false)
    }

    @Test func checkpointOnlySessionHasNoWork() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let session = try store.startSession(for: nil)
        try session.journal.append(.checkpoint(sourceURL: nil))
        let plan = try #require(store.recoverableSessions().first)
        #expect(plan.hasWork == false)
        store.discard(plan)
        #expect(store.recoverableSessions().isEmpty)
    }

    @Test func checkpointSavedFlattensLogButKeepsUndoHistory() throws {
        let a = richStage()
        let journal = InMemoryCommandJournal()
        let stack = CommandStack(stage: a, journal: journal)
        try stack.run(cmd("Hide", [.setActive(path: bodyPath, isActive: false)]))
        stack.checkpointSaved(sourceURL: URL(fileURLWithPath: "/tmp/saved.usda"))
        // The durable log is flattened to a single fresh checkpoint...
        let records = try journal.readAll()
        #expect(records.count == 1)
        #expect(records.first == .checkpoint(sourceURL: URL(fileURLWithPath: "/tmp/saved.usda")))
        // ...but the in-memory undo history survives so ⌘Z still works post-save.
        #expect(stack.canUndo)
    }

    @Test func checkpointSavedIsNoOpWithoutJournal() throws {
        let stack = CommandStack(stage: richStage())   // no journal
        try stack.run(cmd("Hide", [.setActive(path: bodyPath, isActive: false)]))
        stack.checkpointSaved(sourceURL: nil)          // must not crash
        #expect(stack.canUndo)
    }

    @Test func journalForPlanReopensExistingWAL() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let session = try store.startSession(for: nil)
        try session.journal.append(.checkpoint(sourceURL: nil))
        try session.journal.append(.command(label: "A", forward: [], inverse: []))
        let plan = try #require(store.recoverableSessions().first)
        // Reopening the plan's WAL keeps appending to the same log.
        let journal = try store.journal(for: plan)
        try journal.append(.undo)
        #expect(try journal.readAll().count == 3)
    }

    @Test func missingRootYieldsNoSessions() {
        let store = SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID())"))
        #expect(store.recoverableSessions().isEmpty)
    }

    @Test func defaultStorePointsAtSessionsDir() {
        let store = SessionStore.defaultStore(appName: "TestApp")
        #expect(store.root.lastPathComponent == "Sessions")
        #expect(store.root.deletingLastPathComponent().lastPathComponent == "TestApp")
    }
}

/// Tiny thread-safe counter for onChange assertions.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = 0
    func bump() { lock.lock(); _v += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
}
