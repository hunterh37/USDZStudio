import USDCore

/// Binds an *existing* material to a prim, undoably.
///
/// This is the "I already have the material I want — point this prim at it" path,
/// the counterpart to ``CreateMaterialCommand`` (which mints a fresh material per
/// call). It exists so repeated bindings of one logical material — e.g. every
/// expanded copy of a repetition system — share a single `/Looks/Material_N`
/// instead of duplicating it per target (#140, #141).
///
/// Like ``CreateMaterialCommand``, the bind is expressed as a remove + re-insert
/// of the target prim carrying a `material:binding` relationship, since the
/// mutation vocabulary has no "author a relationship" primitive. Any prior
/// binding on the target is replaced; undo restores the exact prior prim.
public struct BindMaterialCommand: EditCommand {
    public let label: String
    /// The material this binds to (echoed back to callers).
    public let materialPath: PrimPath
    private let forward: [StageMutation]
    private let inverse: [StageMutation]

    private static let bindingKey = MaterialBinding.key

    /// Builds the command, or `nil` when `target` isn't on the stage, `material`
    /// isn't a Material prim, or the binding is already exactly in place (no-op).
    ///
    /// - Parameters:
    ///   - target: the prim to bind — its subtree inherits the material.
    ///   - material: the path of an existing `Material` prim.
    ///   - stage: the stage to resolve indices and validate against.
    public static func make(
        binding target: PrimPath,
        to material: PrimPath,
        in stage: any USDStageProtocol
    ) -> BindMaterialCommand? {
        guard stage.prim(at: material)?.typeName == "Material" else { return nil }
        guard let (targetPrim, targetParent, targetIndex) = locate(target, in: stage) else { return nil }

        // No-op guard: the target already binds exactly this material directly.
        if let existing = targetPrim.relationships.first(where: { $0.name == bindingKey }),
           existing.targets == [material] {
            return nil
        }

        var boundTarget = targetPrim
        boundTarget.relationships.removeAll { $0.name == bindingKey }
        boundTarget.relationships.append(
            Relationship(name: bindingKey, targets: [material]))

        let forward: [StageMutation] = [
            .removePrim(path: target),
            .insertPrim(parent: targetParent, index: targetIndex, prim: boundTarget),
        ]
        let inverse: [StageMutation] = [
            .removePrim(path: target),
            .insertPrim(parent: targetParent, index: targetIndex, prim: targetPrim),
        ]

        return BindMaterialCommand(
            label: "Bind \(material.name) to \(target.name)",
            materialPath: material, forward: forward, inverse: inverse)
    }

    public func execute(on stage: any USDStageMutable) throws {
        for mutation in forward { try stage.apply(mutation) }
    }

    public func undo(on stage: any USDStageMutable) throws {
        for mutation in inverse { try stage.apply(mutation) }
    }

    /// The prim at `path` plus its parent path and sibling index.
    private static func locate(
        _ path: PrimPath, in stage: any USDStageProtocol
    ) -> (Prim, PrimPath?, Int)? {
        if let i = stage.rootPrims.firstIndex(where: { $0.path == path }) {
            return (stage.rootPrims[i], nil, i)
        }
        let parentPath = path.parent
        guard let parent = stage.prim(at: parentPath),
              let i = parent.children.firstIndex(where: { $0.path == path }) else { return nil }
        return (parent.children[i], parentPath, i)
    }
}
