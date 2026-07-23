import USDCore

/// Binds an **existing** material to a target prim, undoably — the DRY
/// counterpart to ``CreateMaterialCommand`` (issue #141).
///
/// `CreateMaterialCommand` mints a fresh `/Looks/Material_N` every call, so
/// patching N unbound prims to share one logical material produced N identical
/// duplicate materials. This command instead points a prim's `material:binding`
/// relationship at a material that is already on the stage, so one material can
/// clothe many targets (e.g. every repetition-system copy of a facade).
///
/// Binding is authored the same way `CreateMaterialCommand` does it: the
/// mutation vocabulary has no "author a relationship" primitive, so the bind is
/// a remove + re-insert of the target prim at the same sibling index with the
/// relationship replaced. The forward/inverse mutation lists are captured at
/// build time, keeping `execute`/`undo` trivial and exactly reversible.
public struct BindMaterialCommand: EditCommand {
    public let label: String
    /// The material this command binds (already on the stage).
    public let materialPath: PrimPath
    /// The prim the binding is authored on.
    public let targetPath: PrimPath
    private let forward: [StageMutation]
    private let inverse: [StageMutation]

    private static let bindingKey = MaterialBinding.key

    /// Builds the command, or `nil` when the target is missing, the material is
    /// missing / not a `Material` prim, or the target already binds exactly this
    /// material (nothing to do — avoids a no-op undo entry).
    ///
    /// - Parameters:
    ///   - materialPath: an existing `Material` prim to bind. Usually the base
    ///     component's material, reused across repetition copies.
    ///   - target: the prim to author `material:binding` on. Because UsdShade
    ///     bindings inherit *down* namespace, binding on a subtree root clothes
    ///     every mesh under it.
    ///   - stage: the stage to resolve names, indices, and prims against.
    public static func make(
        materialPath: PrimPath,
        bindingTo target: PrimPath,
        in stage: any USDStageProtocol
    ) -> BindMaterialCommand? {
        // The material must exist and actually be a Material prim — binding to a
        // mesh or a missing path would author a dangling relationship.
        guard let material = stage.prim(at: materialPath), material.typeName == "Material" else {
            return nil
        }
        guard let (targetPrim, targetParent, targetIndex) = locate(target, in: stage) else {
            return nil
        }
        // Skip when the direct binding is already this exact material.
        let existing = targetPrim.relationships.first { $0.name == bindingKey }
        if existing?.targets == [materialPath] { return nil }

        var boundTarget = targetPrim
        boundTarget.relationships.removeAll { $0.name == bindingKey }
        boundTarget.relationships.append(
            Relationship(name: bindingKey, targets: [materialPath]))

        let forward: [StageMutation] = [
            .removePrim(path: target),
            .insertPrim(parent: targetParent, index: targetIndex, prim: boundTarget),
        ]
        let inverse: [StageMutation] = [
            .removePrim(path: target),
            .insertPrim(parent: targetParent, index: targetIndex, prim: targetPrim),
        ]
        return BindMaterialCommand(
            label: "Bind \(materialPath.name) to \(target.name)",
            materialPath: materialPath, targetPath: target,
            forward: forward, inverse: inverse)
    }

    public func execute(on stage: any USDStageMutable) throws {
        for mutation in forward { try stage.apply(mutation) }
    }

    public func undo(on stage: any USDStageMutable) throws {
        for mutation in inverse { try stage.apply(mutation) }
    }

    /// The prim at `path` plus its parent path and sibling index (for exact
    /// remove/re-insert) — mirrors ``CreateMaterialCommand``'s locator.
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
