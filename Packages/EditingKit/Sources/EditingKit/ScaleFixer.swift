import USDCore

/// Normalizes a stage's `metersPerUnit` to a target (1.0 by default) while
/// preserving real-world size — the "my model imported 100× too big" fix that
/// `MetersPerUnitRule` points users toward (specs/validation.md, PRD §5.3).
///
/// Changing `metersPerUnit` alone rescales how the file's numbers map to meters,
/// so geometry visibly grows or shrinks. To keep the rendered size fixed we bake
/// a compensating uniform scale of `oldMetersPerUnit / targetMetersPerUnit` into
/// each root prim's local transform. The metadata edit and the transform edits
/// are wrapped in one `CompositeCommand`, so the whole fix is a single
/// Edit ▸ Undo.
public enum ScaleFixer {

    /// Builds the undoable fix, or `nil` when nothing needs doing (already at the
    /// target scale) or the target is invalid (≤ 0). Root prims with no authored
    /// transform get an explicit scale op; existing transforms are multiplied.
    public static func command(
        for stage: any USDStageProtocol,
        targetMetersPerUnit: Double = 1.0
    ) -> CompositeCommand? {
        let old = stage.metadata
        guard targetMetersPerUnit > 0 else { return nil }
        let factor = old.metersPerUnit / targetMetersPerUnit
        // Nothing to do if already normalized (guard against float dust).
        guard abs(factor - 1.0) > 1e-9 else { return nil }

        var commands: [any EditCommand] = []

        var newMetadata = old
        newMetadata.metersPerUnit = targetMetersPerUnit
        commands.append(SetStageMetadataCommand(newMetadata: newMetadata, oldMetadata: old))

        for root in stage.rootPrims {
            let oldAttribute = root.attribute(named: transformAttributeName)
            var trs = stage.transform(at: root.path)
            trs.scale = trs.scale.map { $0 * factor }
            commands.append(SetTransformCommand(
                path: root.path, newTRS: trs, oldAttribute: oldAttribute, verb: "Scale"))
        }

        return CompositeCommand(label: "Fix Scale", commands: commands)
    }
}
