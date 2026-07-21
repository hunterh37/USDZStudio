import Testing
import Foundation
@testable import SessionKit

/// Coverage for the versioned envelope and both envelope-store backends:
/// round-trips, atomic writes, and graceful degradation on absent / corrupt /
/// incompatible-version files.
struct SessionEnvelopeTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-env-\(UUID().uuidString)")
    }

    private func sampleEnvelope() -> SessionEnvelope {
        SessionEnvelope(document: DocumentSession(
            savedRevision: 2, viewState: ViewState(selectionPaths: ["/A"])))
    }

    // MARK: SessionEnvelope

    @Test func envelopeDefaultsToCurrentVersionAndIsCompatible() {
        let envelope = SessionEnvelope(document: DocumentSession())
        #expect(envelope.schemaVersion == SessionEnvelope.currentSchemaVersion)
        #expect(envelope.isCompatible)
    }

    @Test func envelopeWithBumpedVersionIsIncompatible() {
        let envelope = SessionEnvelope(document: DocumentSession(),
                                       schemaVersion: SessionEnvelope.currentSchemaVersion + 1)
        #expect(envelope.isCompatible == false)
    }

    @Test func envelopeRoundTrips() throws {
        let envelope = sampleEnvelope()
        let data = try JSONEncoder().encode(envelope)
        #expect(try JSONDecoder().decode(SessionEnvelope.self, from: data) == envelope)
    }

    // MARK: FileEnvelopeStore

    @Test func fileEnvelopeRoundTrips() throws {
        let store = FileEnvelopeStore()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.write(sampleEnvelope(), to: dir)
        #expect(store.read(from: dir) == sampleEnvelope())
    }

    @Test func fileEnvelopeReadNilWhenAbsent() {
        #expect(FileEnvelopeStore().read(from: tempDir()) == nil)
    }

    @Test func fileEnvelopeReadNilWhenCorrupt() throws {
        let store = FileEnvelopeStore()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent(FileEnvelopeStore.fileName))
        #expect(store.read(from: dir) == nil)
    }

    @Test func fileEnvelopeReadNilWhenIncompatibleVersion() throws {
        let store = FileEnvelopeStore()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let future = SessionEnvelope(document: DocumentSession(),
                                     schemaVersion: SessionEnvelope.currentSchemaVersion + 1)
        try store.write(future, to: dir)
        #expect(store.read(from: dir) == nil)   // discarded, can't wedge launch
    }

    @Test func fileEnvelopeOverwriteReplacesPrevious() throws {
        let store = FileEnvelopeStore()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.write(sampleEnvelope(), to: dir)
        let updated = SessionEnvelope(document: DocumentSession(savedRevision: 9))
        try store.write(updated, to: dir)
        #expect(store.read(from: dir)?.document.savedRevision == 9)
    }

    // MARK: InMemoryEnvelopeStore

    @Test func inMemoryEnvelopeRoundTrips() throws {
        let store = InMemoryEnvelopeStore()
        let dir = tempDir()
        try store.write(sampleEnvelope(), to: dir)
        #expect(store.read(from: dir) == sampleEnvelope())
    }

    @Test func inMemoryEnvelopeReadNilWhenAbsent() {
        #expect(InMemoryEnvelopeStore().read(from: tempDir()) == nil)
    }

    @Test func inMemoryEnvelopeReadNilWhenIncompatible() throws {
        let store = InMemoryEnvelopeStore()
        let dir = tempDir()
        try store.write(SessionEnvelope(document: DocumentSession(),
                                        schemaVersion: SessionEnvelope.currentSchemaVersion + 1),
                        to: dir)
        #expect(store.read(from: dir) == nil)
    }
}
