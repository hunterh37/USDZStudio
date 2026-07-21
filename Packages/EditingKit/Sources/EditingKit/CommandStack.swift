import Foundation
import USDCore

/// The editor's undo/redo command layer.
///
/// Every mutation the user makes flows through `run(_:)`, which executes the
/// command against the stage and pushes it onto the undo stack. `undo()` and
/// `redo()` replay a command's inverse or re-apply. Running a fresh command
/// clears the redo stack, matching standard editor semantics.
///
/// When constructed with a `CommandJournal`, the stack additionally maintains a
/// crash-safe write-ahead log: each stack operation appends one durable record,
/// so a `SIGKILL` or power loss can be recovered by replaying the log against
/// the last-saved document (`recover(records:)`). Every command is captured
/// uniformly through a `JournalingStage` proxy — the general form of the
/// mesh-edit session journal.
///
/// The stack is UI-agnostic; `UndoManagerBridge` wires it to AppKit's
/// `NSUndoManager` so the app's Edit menu, ⌘Z/⇧⌘Z, and document dirty-state all
/// work without the stack knowing anything about AppKit.
public final class CommandStack: @unchecked Sendable {
    private let stage: any USDStageMutable
    private let proxy: JournalingStage
    private let journal: (any CommandJournal)?
    private var undoStack: [any EditCommand] = []
    private var redoStack: [any EditCommand] = []
    private let lock = NSLock()

    /// Called after any change to the stack (run/undo/redo). Use it to refresh
    /// the viewport and menu-item enablement.
    public var onChange: (@Sendable () -> Void)?

    /// Creates a stack over `stage`. Pass a `journal` to enable the crash-safe
    /// WAL; a `checkpoint` for `stage.sourceURL` is written immediately so
    /// recovery knows which document to replay against.
    public convenience init(stage: any USDStageMutable, journal: (any CommandJournal)? = nil) {
        self.init(stage: stage, journal: journal, writeCheckpoint: true)
    }

    private init(stage: any USDStageMutable, journal: (any CommandJournal)?, writeCheckpoint: Bool) {
        self.stage = stage
        self.proxy = JournalingStage(stage)
        self.journal = journal
        if writeCheckpoint {
            try? journal?.append(.checkpoint(sourceURL: stage.sourceURL))
        }
    }

    /// Builds a stack that continues an *existing* WAL after a crash: it does
    /// not write a new checkpoint (that would truncate history), replays
    /// `records` to restore the exact command stack + stage content, then keeps
    /// appending to the same `journal`. Pass the records that follow the last
    /// checkpoint (see `SessionStore.RecoveryPlan`).
    public static func recovered(
        stage: any USDStageMutable,
        journal: (any CommandJournal)?,
        records: [JournalRecord]
    ) throws -> CommandStack {
        let stack = CommandStack(stage: stage, journal: journal, writeCheckpoint: false)
        try stack.recover(records: records)
        return stack
    }

    public var canUndo: Bool { lock.withLock { !undoStack.isEmpty } }
    public var canRedo: Bool { lock.withLock { !redoStack.isEmpty } }

    /// Label of the command that would be undone, e.g. "Rename Wheel".
    public var undoLabel: String? { lock.withLock { undoStack.last?.label } }
    /// Label of the command that would be redone.
    public var redoLabel: String? { lock.withLock { redoStack.last?.label } }

    /// Depth of the undo history (for tests / telemetry).
    public var undoCount: Int { lock.withLock { undoStack.count } }
    /// Depth of the redo history (for tests / telemetry).
    public var redoCount: Int { lock.withLock { redoStack.count } }

    /// Executes `command` and records it for undo, clearing the redo stack.
    @discardableResult
    public func run(_ command: any EditCommand) throws -> String {
        if journal != nil {
            proxy.beginTransaction()
            do {
                try command.execute(on: proxy)
            } catch {
                proxy.endTransaction()
                throw error
            }
            let captured = proxy.endTransaction()
            try journal?.append(.command(
                label: command.label, forward: captured.forward, inverse: captured.inverse))
        } else {
            try command.execute(on: stage)
        }
        lock.withLock {
            undoStack.append(command)
            redoStack.removeAll()
        }
        onChange?()
        return command.label
    }

    /// Reverts the most recent command. Returns its label, or `nil` if empty.
    @discardableResult
    public func undo() throws -> String? {
        guard let command = lock.withLock({ undoStack.popLast() }) else { return nil }
        try proxy.withoutRecording { try command.undo(on: proxy) }
        try journal?.append(.undo)
        lock.withLock { redoStack.append(command) }
        onChange?()
        return command.label
    }

    /// Re-applies the most recently undone command. Returns its label, or `nil`.
    @discardableResult
    public func redo() throws -> String? {
        guard let command = lock.withLock({ redoStack.popLast() }) else { return nil }
        try proxy.withoutRecording { try command.execute(on: proxy) }
        try journal?.append(.redo)
        lock.withLock { undoStack.append(command) }
        onChange?()
        return command.label
    }

    /// Clears all history — e.g. after Save flattens the layer or on document
    /// close. Truncates the WAL and writes a fresh checkpoint so the log stays
    /// bounded and always replays from the just-saved state.
    public func clear() {
        lock.withLock {
            undoStack.removeAll()
            redoStack.removeAll()
        }
        try? journal?.reset()
        try? journal?.append(.checkpoint(sourceURL: stage.sourceURL))
        onChange?()
    }

    /// Records a save boundary in the write-ahead log without discarding the
    /// in-memory undo/redo history.
    ///
    /// Truncates the log and writes a fresh checkpoint for `sourceURL`, so crash
    /// recovery (and cross-launch session restore) replays against the
    /// just-saved file with an empty tail — the on-disk state is now the
    /// baseline, and replaying the pre-save commands onto it would double-apply
    /// them. Unlike ``clear()``, the undo/redo stacks are left intact so the user
    /// can still undo past a save in-session; only the durable log is flattened.
    /// A no-op when the stack has no journal.
    public func checkpointSaved(sourceURL: URL?) {
        guard journal != nil else { return }
        try? journal?.reset()
        try? journal?.append(.checkpoint(sourceURL: sourceURL))
    }

    // MARK: Crash recovery

    /// Rebuilds the undo/redo stacks (and the stage content) by replaying WAL
    /// `records` — the records that follow the checkpoint whose document this
    /// stack was opened over. After this returns, `canUndo`/`canRedo`, the
    /// stack depths, and the stage all match the crashed session exactly, and
    /// the WAL continues to grow from where it left off.
    ///
    /// Replay runs directly against the underlying stage (never re-journaled).
    public func recover(records: [JournalRecord]) throws {
        for record in records {
            switch record {
            case .checkpoint:
                // A checkpoint resets history (it marks a save/flatten point).
                lock.withLock { undoStack.removeAll(); redoStack.removeAll() }
            case let .command(label, forward, inverse):
                let command = RecordedCommand(label: label, forward: forward, inverse: inverse)
                try command.execute(on: stage)
                lock.withLock { undoStack.append(command); redoStack.removeAll() }
            case .undo:
                guard let command = lock.withLock({ undoStack.popLast() }) else { continue }
                try command.undo(on: stage)
                lock.withLock { redoStack.append(command) }
            case .redo:
                guard let command = lock.withLock({ redoStack.popLast() }) else { continue }
                try command.execute(on: stage)
                lock.withLock { undoStack.append(command) }
            }
        }
        onChange?()
    }
}
