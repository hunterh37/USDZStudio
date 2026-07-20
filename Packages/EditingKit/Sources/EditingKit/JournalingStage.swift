import Foundation
import USDCore

/// A transparent `USDStageMutable` proxy that records, for every mutation a
/// command applies, both the forward mutation and its computed inverse.
///
/// `CommandStack` wraps the document's real stage in one of these. While a
/// command executes, the stack opens a *transaction*; each `apply` the command
/// makes is forwarded to the real stage and, if recording is on, captured. On
/// commit the stack reads the captured `forward`/`inverse` lists and writes one
/// `JournalRecord.command`. Undo/redo temporarily switch recording off (they're
/// logged as `.undo`/`.redo` markers, not fresh commands) while still mutating
/// the underlying stage.
///
/// This is the generalization of the mesh-edit session journal: it captures
/// *any* command's effects uniformly, with no per-command bookkeeping.
final class JournalingStage: USDStageMutable, @unchecked Sendable {
    let wrapped: any USDStageMutable
    private let lock = NSLock()
    private var recording = false
    private var forward: [StageMutation] = []
    private var inverse: [StageMutation] = []

    init(_ wrapped: any USDStageMutable) {
        self.wrapped = wrapped
    }

    // MARK: USDStageProtocol (pure passthrough)

    var sourceURL: URL? { wrapped.sourceURL }
    var metadata: StageMetadata { wrapped.metadata }
    var rootPrims: [Prim] { wrapped.rootPrims }

    // MARK: USDStageMutable

    func apply(_ mutation: StageMutation) throws {
        // Compute the inverse against the *pre-apply* state, then apply.
        let inv = recording ? mutation.inverse(reading: wrapped) : nil
        try wrapped.apply(mutation)
        if recording, let inv {
            lock.withLock {
                forward.append(mutation)
                inverse.append(inv)
            }
        }
    }

    // MARK: Transaction control (used by CommandStack)

    /// Begins capturing mutations for the command about to execute.
    func beginTransaction() {
        lock.withLock {
            recording = true
            forward.removeAll(keepingCapacity: true)
            inverse.removeAll(keepingCapacity: true)
        }
    }

    /// Ends capture and returns what was recorded.
    @discardableResult
    func endTransaction() -> (forward: [StageMutation], inverse: [StageMutation]) {
        lock.withLock {
            recording = false
            return (forward, inverse)
        }
    }

    /// Runs `body` with recording suppressed — for in-session undo/redo, which
    /// mutate the stage but must not be captured as new command records.
    func withoutRecording<T>(_ body: () throws -> T) rethrows -> T {
        let was = lock.withLock { let w = recording; recording = false; return w }
        defer { lock.withLock { recording = was } }
        return try body()
    }
}
