import Foundation
import USDCore
import EditingKit

/// The inputs `CommandStack.recovered(stage:journal:records:)` needs to rebuild
/// a crashed session's undo/redo history: the base document the log replays
/// against, and the records that follow the log's last checkpoint.
///
/// A WAL is a sequence of `JournalRecord`s that opens with a `.checkpoint`
/// (naming the base document) and may contain later checkpoints written after a
/// save/clear flattened history. Recovery only needs to replay from the *last*
/// checkpoint — everything before it was already folded into a saved file — so
/// this splits the log there.
public struct RecoveryPlan: Equatable, Sendable {
    /// The document URL the last checkpoint was taken against (`nil` for a
    /// scratch scene checkpoint).
    public var sourceURL: URL?
    /// The records after the last checkpoint, to replay in order.
    public var records: [JournalRecord]

    public init(sourceURL: URL?, records: [JournalRecord]) {
        self.sourceURL = sourceURL
        self.records = records
    }

    /// Derives a plan from a full WAL. Returns `nil` when the log contains no
    /// checkpoint at all (an empty or never-opened journal), meaning there is
    /// nothing to recover.
    ///
    /// A single pass tracks the most recent checkpoint's URL and the index after
    /// it, so only the post-checkpoint tail is replayed (earlier records were
    /// folded into a saved file at that checkpoint).
    public static func derive(from journal: [JournalRecord]) -> RecoveryPlan? {
        var foundCheckpoint = false
        var sourceURL: URL?
        var tailStart = 0
        for (index, record) in journal.enumerated() {
            if case let .checkpoint(url) = record {
                foundCheckpoint = true
                sourceURL = url
                tailStart = index + 1
            }
        }
        guard foundCheckpoint else { return nil }
        return RecoveryPlan(sourceURL: sourceURL, records: Array(journal[tailStart...]))
    }

    /// `true` when there are no post-checkpoint records — the document was at its
    /// last-saved state with an empty undo stack, so recovery is a no-op.
    public var isEmpty: Bool { records.isEmpty }
}
