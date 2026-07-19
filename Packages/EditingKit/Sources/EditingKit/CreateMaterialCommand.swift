import USDCore

/// Creates a new UsdPreviewSurface material and binds it to a prim, undoably.
///
/// This is the "the model has no material yet — give it one I can recolour" path.
/// It authors three things as a single undo entry:
///
/// 1. a `Scope` to hold materials (`/Looks`), created only if one isn't already
///    there;
/// 2. a `Material` prim with a `UsdPreviewSurface` `Shader` child carrying an
///    initial `diffuseColor`; and
/// 3. a `material:binding` relationship on the target prim pointing at it.
///
/// Because UsdShade bindings inherit *down* namespace, binding on a model's root
/// makes every mesh under it render the new material — so a single created
/// material recolours the whole model, and `MaterialBinding.resolve` then finds
/// it from any part.
///
/// The mutation vocabulary has no "author a relationship" primitive, so the bind
/// is expressed by replacing the target prim with a copy that carries the
/// relationship (remove + re-insert at the same index). The command records the
/// exact forward and inverse mutation lists at build time, keeping `execute` /
/// `undo` trivial and exactly reversible.
public struct CreateMaterialCommand: EditCommand {
    public let label: String
    /// The path the new material lands at — callers may want to select it.
    public let materialPath: PrimPath
    /// The surface prim its inputs live on (the shader child).
    public let surfacePath: PrimPath
    private let forward: [StageMutation]
    private let inverse: [StageMutation]

    /// The relationship name UsdShade binds materials with.
    private static let bindingKey = MaterialBinding.key
    /// The container scope new materials are created under.
    private static let looksScopeName = "Looks"

    /// Builds the command, or `nil` when `target` isn't on the stage.
    ///
    /// - Parameters:
    ///   - target: the prim to bind the new material to — usually the selected
    ///     model root, so the whole subtree inherits it.
    ///   - baseColor: the initial linear `diffuseColor` (defaults to a neutral
    ///     grey matching the USD fallback).
    ///   - stage: the stage to resolve names, indices, and the target against.
    public static func make(
        bindingTo target: PrimPath,
        baseColor: [Double] = [0.18, 0.18, 0.18],
        in stage: any USDStageProtocol
    ) -> CreateMaterialCommand? {
        guard let (targetPrim, targetParent, targetIndex) = locate(target, in: stage) else { return nil }

        // 1. Find or plan the /Looks scope.
        let existingScope = stage.rootPrims.first {
            $0.typeName == "Scope" && $0.name == looksScopeName
        }
        let scopePath = existingScope?.path ?? PrimPath("/\(looksScopeName)")!

        // 2. A unique material name under the scope.
        let siblingNames = Set((existingScope?.children ?? []).map(\.name))
        let materialName = uniqueName("Material", taken: siblingNames)
        guard let materialPath = scopePath.appending(materialName),
              let surfacePath = materialPath.appending("Surface") else { return nil }

        // 3. Build the material + shader subtree.
        let shader = Prim(
            path: surfacePath, typeName: "Shader",
            attributes: [
                Attribute(name: "info:id", value: .token(MaterialBinding.previewSurfaceID)),
                Attribute(name: "inputs:diffuseColor", value: .vector(baseColor)),
            ])
        let material = Prim(path: materialPath, typeName: "Material", children: [shader])

        // 4. The target copy carrying the binding (any prior binding replaced).
        var boundTarget = targetPrim
        boundTarget.relationships.removeAll { $0.name == bindingKey }
        boundTarget.relationships.append(
            Relationship(name: bindingKey, targets: [materialPath]))

        // Create the material (inside a fresh scope, appended so it never shifts
        // the target's index) before rebinding the target.
        let createMaterial: StageMutation
        let removeMaterial: StageMutation
        if existingScope != nil {
            createMaterial = .insertPrim(
                parent: scopePath, index: existingScope!.children.count, prim: material)
            removeMaterial = .removePrim(path: materialPath)
        } else {
            let scope = Prim(path: scopePath, typeName: "Scope", children: [material])
            createMaterial = .insertPrim(
                parent: nil, index: stage.rootPrims.count, prim: scope)
            removeMaterial = .removePrim(path: scopePath)
        }

        let forward: [StageMutation] = [
            createMaterial,
            .removePrim(path: target),
            .insertPrim(parent: targetParent, index: targetIndex, prim: boundTarget),
        ]
        let inverse: [StageMutation] = [
            .removePrim(path: target),
            .insertPrim(parent: targetParent, index: targetIndex, prim: targetPrim),
            removeMaterial,
        ]

        return CreateMaterialCommand(
            label: "Create Material on \(target.name)",
            materialPath: materialPath, surfacePath: surfacePath,
            forward: forward, inverse: inverse)
    }

    public func execute(on stage: any USDStageMutable) throws {
        for mutation in forward { try stage.apply(mutation) }
    }

    public func undo(on stage: any USDStageMutable) throws {
        for mutation in inverse { try stage.apply(mutation) }
    }

    // MARK: Helpers

    /// The prim at `path` plus its parent path and sibling index (for exact
    /// remove/re-insert).
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

    /// `base`, or `base_1`, `base_2`… — the first name not already taken.
    private static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 1
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }
}
