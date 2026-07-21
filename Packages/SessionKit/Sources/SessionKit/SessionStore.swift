import Foundation
import Observation
import EditingKit

/// Coordinates capture and restore of the app session over an injectable
/// ``SessionPersistence`` backend.
///
/// It is intentionally UI-agnostic and data-only: it never imports the editor's
/// document type. The EditorUI layer builds a ``DocumentSession`` from the live
/// document and calls ``save(_:)``; on launch it calls ``load()`` and, for the
/// restored document, ``recoveryPlan(for:)`` + ``journal(for:)`` to hand
/// `CommandStack` exactly what it needs to replay the write-ahead log.
///
/// Every failure degrades to "no session to restore" — restoration must never be
/// able to block launch — and the reason is recorded in ``lastLoadOutcome`` for
/// the UI and tests.
@Observable
@MainActor
public final class SessionStore {

    /// Why the most recent ``load()`` returned what it did.
    public enum LoadOutcome: Equatable, Sendable {
        /// A compatible, non-empty session was returned for restoration.
        case restored
        /// No session had been written (or it held no documents).
        case empty
        /// The envelope's schema version is not understood by this build; it was
        /// discarded and a clean start begun.
        case discardedIncompatible
        /// The stored envelope could not be decoded; it was discarded.
        case discardedCorrupt
    }

    @ObservationIgnored private let persistence: any SessionPersistence

    /// The outcome of the last ``load()`` call (`.empty` before the first).
    public private(set) var lastLoadOutcome: LoadOutcome = .empty

    public init(persistence: any SessionPersistence) {
        self.persistence = persistence
    }

    /// Convenience: the default Application Support file backend.
    public convenience init() {
        self.init(persistence: FileSessionPersistence.applicationSupport())
    }

    // MARK: Load / save

    /// Loads a restorable session, or `nil` when there is nothing compatible to
    /// restore. A corrupt or version-incompatible envelope is discarded so it
    /// can never wedge a future launch. Sets ``lastLoadOutcome``.
    public func load() -> SessionState? {
        do {
            let state = try persistence.loadState()
            guard state.schemaVersion == SessionState.currentSchemaVersion else {
                try? persistence.deleteAll()
                lastLoadOutcome = .discardedIncompatible
                return nil
            }
            guard !state.documents.isEmpty else {
                lastLoadOutcome = .empty
                return nil
            }
            lastLoadOutcome = .restored
            return state
        } catch {
            try? persistence.deleteAll()
            lastLoadOutcome = .discardedCorrupt
            return nil
        }
    }

    /// Persists `state` best-effort. A write failure is swallowed: failing to
    /// capture a session must never surface as an error to the user mid-edit.
    public func save(_ state: SessionState) {
        try? persistence.saveState(state)
    }

    /// Drops all session data — on a clean quit or when the user declines a
    /// restore.
    public func clear() {
        try? persistence.deleteAll()
    }

    // MARK: Recovery

    /// The replay plan for `document`'s write-ahead log, or `nil` when the log
    /// has no checkpoint (nothing to recover).
    public func recoveryPlan(for document: DocumentSession) -> RecoveryPlan? {
        let records = (try? persistence.readJournalRecords(
            relativePath: document.journalRelativePath)) ?? []
        return RecoveryPlan.derive(from: records)
    }

    /// A journal for `document` the caller can keep appending to after restore,
    /// or `nil` if one can't be opened.
    public func journal(for document: DocumentSession) -> (any CommandJournal)? {
        try? persistence.makeJournal(relativePath: document.journalRelativePath)
    }
}
