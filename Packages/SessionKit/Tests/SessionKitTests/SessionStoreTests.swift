import Testing
import Foundation
import EditingKit
@testable import SessionKit

/// Coverage for the store coordinator: load outcomes (restored / empty /
/// incompatible / corrupt), save, clear, and recovery-plan/journal access.
@MainActor
struct SessionStoreTests {

    private func tempFileBackend() -> FileSessionPersistence {
        FileSessionPersistence(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-store-\(UUID().uuidString)"))
    }

    private func documentState() -> SessionState {
        SessionState(document: DocumentSession(journalRelativePath: "journal.jsonl",
                                               savedRevision: 1))
    }

    @Test func loadReturnsNilAndEmptyOutcomeWhenNothingStored() {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        #expect(store.load() == nil)
        #expect(store.lastLoadOutcome == .empty)
    }

    @Test func loadRestoresStoredDocument() {
        let persistence = InMemorySessionPersistence(state: documentState())
        let store = SessionStore(persistence: persistence)
        let loaded = store.load()
        #expect(loaded?.documents.count == 1)
        #expect(store.lastLoadOutcome == .restored)
    }

    @Test func loadDiscardsIncompatibleSchema() throws {
        let persistence = InMemorySessionPersistence()
        var state = documentState()
        state.schemaVersion = SessionState.currentSchemaVersion + 1
        try persistence.saveState(state)
        let store = SessionStore(persistence: persistence)
        #expect(store.load() == nil)
        #expect(store.lastLoadOutcome == .discardedIncompatible)
        // The incompatible envelope was dropped.
        #expect(try persistence.loadState().documents.isEmpty)
    }

    @Test func loadDiscardsCorruptState() throws {
        let backend = tempFileBackend()
        defer { try? backend.deleteAll() }
        try backend.saveState(documentState())
        try Data("{bad".utf8).write(to: backend.sessionsDirectory
            .appendingPathComponent("session.json"))
        let store = SessionStore(persistence: backend)
        #expect(store.load() == nil)
        #expect(store.lastLoadOutcome == .discardedCorrupt)
        // Corrupt file removed so it can't wedge the next launch.
        #expect(try backend.loadState().documents.isEmpty)
    }

    @Test func saveThenLoadRoundTrips() {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        store.save(documentState())
        #expect(store.load()?.documents.count == 1)
    }

    @Test func clearDropsSession() throws {
        let persistence = InMemorySessionPersistence(state: documentState())
        let store = SessionStore(persistence: persistence)
        store.clear()
        #expect(try persistence.loadState().documents.isEmpty)
    }

    @Test func recoveryPlanReadsDocumentJournal() throws {
        let persistence = InMemorySessionPersistence()
        let journal = try persistence.makeJournal(relativePath: "journal.jsonl")
        try journal.append(.checkpoint(sourceURL: nil))
        try journal.append(.command(label: "Edit", forward: [], inverse: []))
        let store = SessionStore(persistence: persistence)
        let doc = DocumentSession(journalRelativePath: "journal.jsonl")
        let plan = store.recoveryPlan(for: doc)
        #expect(plan?.records.count == 1)
    }

    @Test func recoveryPlanIsNilWithoutCheckpoint() {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        let doc = DocumentSession(journalRelativePath: "empty.jsonl")
        #expect(store.recoveryPlan(for: doc) == nil)
    }

    @Test func journalForDocumentIsUsable() throws {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        let doc = DocumentSession(journalRelativePath: "journal.jsonl")
        let journal = try #require(store.journal(for: doc))
        try journal.append(.undo)
        #expect(try journal.readAll() == [.undo])
    }

    @Test func defaultConvenienceInitConstructs() {
        // Exercises the Application Support convenience initializer (without
        // reading real user state).
        let store = SessionStore()
        #expect(store.lastLoadOutcome == .empty)
    }
}
