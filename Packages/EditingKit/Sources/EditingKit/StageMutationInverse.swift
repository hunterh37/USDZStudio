import USDCore

/// Computes the *inverse* of a mutation from the stage state that exists **just
/// before** the mutation is applied.
///
/// This is what lets the crash-safe command journal (see `CommandJournal`)
/// generalize the mesh-edit session journal to every command: rather than
/// asking each `EditCommand` to hand-author its own undo, the `JournalingStage`
/// proxy records, for each forward `StageMutation` a command applies, the
/// mutation that reverses it. Replaying `forward` reconstructs the crashed
/// session's stage; replaying `inverse` (in reverse order) undoes it — so the
/// exact undo/redo stacks survive a crash.
///
/// The inverse is always expressed in the same closed `StageMutation`
/// vocabulary, so recovery needs no special-case machinery.
extension StageMutation {

    /// The mutation that undoes `self`, read against `stage` *before* `self` is
    /// applied. `nil` only when the pre-state can't be read (e.g. the target
    /// prim is missing) — the caller treats that as a non-journalable mutation.
    func inverse(reading stage: any USDStageProtocol) -> StageMutation? {
        switch self {
        case let .setAttribute(path, attribute):
            guard let prim = stage.prim(at: path) else { return nil }
            if let existing = prim.attribute(named: attribute.name) {
                return .setAttribute(path: path, attribute: existing)
            }
            return .removeAttribute(path: path, name: attribute.name)

        case let .removeAttribute(path, name):
            guard let prim = stage.prim(at: path) else { return nil }
            if let existing = prim.attribute(named: name) {
                return .setAttribute(path: path, attribute: existing)
            }
            // Attribute already absent — removal is a no-op, so is its inverse.
            return .removeAttribute(path: path, name: name)

        case let .setVisibility(path, _):
            guard let prim = stage.prim(at: path) else { return nil }
            return .setVisibility(path: path, visibility: prim.visibility)

        case let .setActive(path, _):
            guard let prim = stage.prim(at: path) else { return nil }
            return .setActive(path: path, isActive: prim.isActive)

        case let .renamePrim(path, newName):
            guard let newPath = path.parent.appending(newName) else { return nil }
            return .renamePrim(path: newPath, newName: path.name)

        case let .removePrim(path):
            // Capture the whole subtree and where it sits so it can be restored.
            guard let (parent, index, prim) = Self.locate(path, in: stage) else { return nil }
            return .insertPrim(parent: parent, index: index, prim: prim)

        case let .insertPrim(_, _, prim):
            return .removePrim(path: prim.path)

        case .setStageMetadata:
            return .setStageMetadata(stage.metadata)

        case let .setVariantSelection(path, setName, _):
            guard let prim = stage.prim(at: path),
                  let set = prim.variantSets.first(where: { $0.name == setName })
            else { return nil }
            return .setVariantSelection(path: path, setName: setName, selection: set.selection)
        }
    }

    /// Finds the prim at `path` and its position: `(parentPathOrNilForRoot,
    /// indexAmongSiblings, primSubtree)`.
    private static func locate(
        _ path: PrimPath, in stage: any USDStageProtocol
    ) -> (parent: PrimPath?, index: Int, prim: Prim)? {
        guard let prim = stage.prim(at: path) else { return nil }
        let parentPath = path.parent
        let siblings = parentPath.isRoot ? stage.rootPrims : (stage.prim(at: parentPath)?.children ?? [])
        guard let index = siblings.firstIndex(where: { $0.path == path }) else { return nil }
        return (parentPath.isRoot ? nil : parentPath, index, prim)
    }
}
