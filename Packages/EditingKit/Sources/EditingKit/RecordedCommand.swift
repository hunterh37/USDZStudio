import USDCore

/// A command reconstructed from a journal record during crash recovery.
///
/// In-session, undo/redo run the *original* `EditCommand` (which knows its own
/// fast inverse). After a crash the originals are gone — all that survives is
/// the WAL's `forward`/`inverse` mutation lists. `RecordedCommand` wraps those
/// so the rebuilt `CommandStack` has real, replayable commands: `execute`
/// applies `forward` in order; `undo` applies `inverse` in reverse order.
public struct RecordedCommand: EditCommand {
    public let label: String
    public let forward: [StageMutation]
    public let inverse: [StageMutation]

    public init(label: String, forward: [StageMutation], inverse: [StageMutation]) {
        self.label = label
        self.forward = forward
        self.inverse = inverse
    }

    public func execute(on stage: any USDStageMutable) throws {
        for mutation in forward { try stage.apply(mutation) }
    }

    public func undo(on stage: any USDStageMutable) throws {
        for mutation in inverse.reversed() { try stage.apply(mutation) }
    }
}
