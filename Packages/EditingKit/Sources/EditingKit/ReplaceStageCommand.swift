import USDCore

/// Replaces the entire stage content — metadata plus the whole root-prim forest —
/// as a single undoable command.
///
/// This is the seam that turns one interactive-console (REPL) submission into one
/// undoable unit (ROADMAP Milestone 5 — "single-undo script runs"). A console
/// submission runs a Python interpreter against a file copy of the live stage; the
/// resulting document is re-opened into an `after` snapshot, and the difference is
/// applied here wholesale rather than diffed into individual edits — the script can
/// do anything usd-core allows, so the command makes no assumption about *what*
/// changed.
///
/// It is expressed purely through the existing `StageMutation` vocabulary
/// (`setStageMetadata` + `removePrim` + `insertPrim`), so it journals to the
/// crash-safe WAL exactly like every other command, with no new mutation case.
///
/// Precondition (upheld by `CommandStack`): the stage equals `before` when
/// `execute` runs (first run and every redo) and equals `after` when `undo` runs —
/// the same absolute-write assumption `MeshEditCommand` relies on.
public struct ReplaceStageCommand: EditCommand {
    public let before: StageSnapshot
    public let after: StageSnapshot
    /// Human label for Edit ▸ Undo, e.g. `Console: stage.DefinePrim(...)`.
    public let opLabel: String

    public init(before: StageSnapshot, after: StageSnapshot, opLabel: String) {
        self.before = before
        self.after = after
        self.opLabel = opLabel
    }

    public var label: String { opLabel }

    public func execute(on stage: any USDStageMutable) throws {
        try replace(current: before, with: after, on: stage)
    }

    public func undo(on stage: any USDStageMutable) throws {
        try replace(current: after, with: before, on: stage)
    }

    /// Removes every root of `current` then inserts every root of `target`, so no
    /// name collision can occur even when the two forests share root names.
    private func replace(current: StageSnapshot,
                         with target: StageSnapshot,
                         on stage: any USDStageMutable) throws {
        try stage.apply(.setStageMetadata(target.metadata))
        for prim in current.rootPrims {
            try stage.apply(.removePrim(path: prim.path))
        }
        for (index, prim) in target.rootPrims.enumerated() {
            try stage.apply(.insertPrim(parent: nil, index: index, prim: prim))
        }
    }
}
