import Testing
import Foundation
import EditingKit
@testable import SessionKit

/// Coverage for both persistence backends: state round-trips, atomic writes,
/// absence vs corruption, deletion, and journal creation/reads.
struct PersistenceTests {

    private func tempBase() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-persist-\(UUID().uuidString)")
        return base
    }

    private func sampleState() -> SessionState {
        SessionState(document: DocumentSession(
            journalRelativePath: "journal.jsonl",
            savedRevision: 2,
            viewState: ViewState(selectionPaths: ["/A"])))
    }

    // MARK: FileSessionPersistence

    @Test func fileStateRoundTrips() throws {
        let p = FileSessionPersistence(baseDirectory: tempBase())
        defer { try? p.deleteAll() }
        let state = sampleState()
        try p.saveState(state)
        #expect(try p.loadState() == state)
    }

    @Test func fileLoadReturnsEmptyWhenAbsent() throws {
        let p = FileSessionPersistence(baseDirectory: tempBase())
        let loaded = try p.loadState()
        #expect(loaded.documents.isEmpty)
        #expect(loaded.schemaVersion == SessionState.currentSchemaVersion)
    }

    @Test func fileLoadThrowsOnCorruptState() throws {
        let base = tempBase()
        let p = FileSessionPersistence(baseDirectory: base)
        defer { try? p.deleteAll() }
        try p.saveState(sampleState())          // creates the directory
        // Overwrite with garbage.
        try Data("{ not json".utf8).write(to: p.sessionsDirectory
            .appendingPathComponent("session.json"))
        #expect(throws: SessionError.corruptState) { _ = try p.loadState() }
    }

    @Test func fileDeleteAllRemovesEverything() throws {
        let p = FileSessionPersistence(baseDirectory: tempBase())
        try p.saveState(sampleState())
        try p.deleteAll()
        #expect(try p.loadState().documents.isEmpty)
        // Deleting again (directory absent) is a no-op, not an error.
        try p.deleteAll()
    }

    @Test func fileJournalRoundTrips() throws {
        let p = FileSessionPersistence(baseDirectory: tempBase())
        defer { try? p.deleteAll() }
        let journal = try p.makeJournal(relativePath: "journal.jsonl")
        try journal.append(.checkpoint(sourceURL: nil))
        try journal.append(.command(label: "Edit", forward: [], inverse: []))
        let records = try p.readJournalRecords(relativePath: "journal.jsonl")
        #expect(records.count == 2)
    }

    @Test func fileJournalRecordsEmptyWhenAbsent() throws {
        let p = FileSessionPersistence(baseDirectory: tempBase())
        #expect(try p.readJournalRecords(relativePath: "missing.jsonl").isEmpty)
    }

    @Test func fileJournalURLIsUnderSessionsDirectory() {
        let base = tempBase()
        let p = FileSessionPersistence(baseDirectory: base)
        let url = p.journalURL(relativePath: "journal.jsonl")
        #expect(url.deletingLastPathComponent() == p.sessionsDirectory)
    }

    @Test func applicationSupportBackendPointsAtNamedFolder() {
        let p = FileSessionPersistence.applicationSupport(appDirectoryName: "OpenUSDZEditorTest")
        #expect(p.sessionsDirectory.pathComponents.contains("OpenUSDZEditorTest"))
        #expect(p.sessionsDirectory.lastPathComponent == "Sessions")
    }

    // MARK: InMemorySessionPersistence

    @Test func inMemoryRoundTrips() throws {
        let p = InMemorySessionPersistence()
        try p.saveState(sampleState())
        #expect(try p.loadState() == sampleState())
    }

    @Test func inMemoryInitialStateIsReturned() throws {
        let p = InMemorySessionPersistence(state: sampleState())
        #expect(try p.loadState() == sampleState())
    }

    @Test func inMemoryEmptyWhenUnset() throws {
        let p = InMemorySessionPersistence()
        #expect(try p.loadState().documents.isEmpty)
    }

    @Test func inMemoryDeleteAllClears() throws {
        let p = InMemorySessionPersistence(state: sampleState())
        try p.deleteAll()
        #expect(try p.loadState().documents.isEmpty)
    }

    @Test func inMemoryJournalIsStableAcrossCalls() throws {
        let p = InMemorySessionPersistence()
        let j1 = try p.makeJournal(relativePath: "j.jsonl")
        try j1.append(.undo)
        // A second makeJournal for the same path returns the same underlying log.
        let j2 = try p.makeJournal(relativePath: "j.jsonl")
        try j2.append(.redo)
        #expect(try p.readJournalRecords(relativePath: "j.jsonl") == [.undo, .redo])
    }
}
