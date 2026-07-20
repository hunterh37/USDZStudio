import USDCore

/// Re-orients a Z-up stage to Y-up while preserving how the model looks — the
/// undoable remedy `UpAxisRule` points users toward ("upAxis is Z; AR QuickLook
/// expects Y-up", specs/validation.md — quick-fixes).
///
/// Flipping `upAxis` metadata alone reinterprets which world axis is "up", so a
/// Z-up model would tip onto its side under AR QuickLook. To keep the rendered
/// orientation fixed we bake a compensating world-space rotation into each root
/// prim: a −90° turn about X, which maps the old up (+Z) onto the new up (+Y).
/// The metadata edit and the per-root transform edits are wrapped in one
/// `CompositeCommand`, so the whole fix is a single Edit ▸ Undo.
public enum UpAxisFixer {

    /// Builds the undoable fix, or `nil` when the stage is not Z-up (nothing to
    /// do). Root prims with no authored transform gain an explicit rotation;
    /// existing transforms are composed with the reorientation in parent space.
    public static func command(for stage: any USDStageProtocol) -> CompositeCommand? {
        let old = stage.metadata
        guard old.upAxis == .z else { return nil }

        var commands: [any EditCommand] = []

        var newMetadata = old
        newMetadata.upAxis = .y
        commands.append(SetStageMetadataCommand(newMetadata: newMetadata, oldMetadata: old))

        // Row-vector convention (p' = p·M): apply the existing local transform,
        // then the world-space reorientation → newMatrix = oldMatrix · R.
        let reorient = Matrix4.rotationX(-Double.pi / 2)
        for root in stage.rootPrims {
            let oldAttribute = root.attribute(named: transformAttributeName)
            let oldMatrix = stage.transform(at: root.path).toMatrix()
            let newMatrix = Matrix4.multiply(oldMatrix, reorient)
            commands.append(SetTransformCommand(
                path: root.path,
                newTRS: TRS.from(matrix: newMatrix),
                oldAttribute: oldAttribute,
                verb: "Reorient"))
        }

        return CompositeCommand(label: "Fix Up Axis", commands: commands)
    }
}
