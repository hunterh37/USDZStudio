import Foundation

/// The top-level, versioned session envelope persisted to `session.json`.
///
/// It is modelled as an *array* of documents from day one even though v1
/// restores a single document (the array is length 0 or 1). This keeps
/// multi-window restoration a purely additive change later — more entries in the
/// same array — rather than a schema migration.
///
/// `schemaVersion` is the forward-compatibility hinge: `SessionStore` discards
/// an envelope whose version it does not recognise (newer than this build, or a
/// version whose migration is not implemented) and starts clean, so a future
/// on-disk format can never wedge an older build's launch. Value migrations for
/// older versions slot into `SessionStore.migrate(_:)`.
public struct SessionState: Equatable, Codable, Sendable {
    /// The schema version this build writes and understands.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var documents: [DocumentSession]

    public init(
        schemaVersion: Int = SessionState.currentSchemaVersion,
        documents: [DocumentSession] = []
    ) {
        self.schemaVersion = schemaVersion
        self.documents = documents
    }

    /// Convenience for the single-document v1 case.
    public init(document: DocumentSession) {
        self.init(documents: [document])
    }

    /// The single document to restore in v1 (the first, if any).
    public var primaryDocument: DocumentSession? { documents.first }
}
