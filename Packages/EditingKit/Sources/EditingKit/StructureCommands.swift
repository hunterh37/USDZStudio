import USDCore

/// Shared tree helpers for the structural commands (reparent / duplicate /
/// group). All reads go through `USDStageProtocol`; nothing here mutates.
enum StructureSupport {

    /// Children of `parent` (root prims when `parent` is `nil`).
    static func children(of parent: PrimPath?, in stage: any USDStageProtocol) -> [Prim] {
        guard let parent else { return stage.rootPrims }
        return stage.prim(at: parent)?.children ?? []
    }

    /// The normalized parent path of `path` — `nil` for a root-level prim.
    static func parent(of path: PrimPath) -> PrimPath? {
        path.depth <= 1 ? nil : path.parent
    }

    /// Sibling index of `path`, or `nil` if it isn't present.
    static func index(of path: PrimPath, in stage: any USDStageProtocol) -> Int? {
        children(of: parent(of: path), in: stage).firstIndex { $0.path == path }
    }

    /// A sibling-unique, valid prim name derived from `base`.
    static func uniqueName(base: String, amongst siblings: Set<String>) -> String {
        let clean = PrimPath.isValidName(base) ? base : PrimPath.sanitizedName(from: base)
        guard siblings.contains(clean) else { return clean }
        var i = 1
        while siblings.contains("\(clean)_\(i)") { i += 1 }
        return "\(clean)_\(i)"
    }

    static func siblingNames(of parent: PrimPath?, in stage: any USDStageProtocol) -> Set<String> {
        Set(children(of: parent, in: stage).map(\.path.name))
    }

    static func childPath(parent: PrimPath?, name: String) -> PrimPath? {
        (parent ?? .root).appending(name)
    }

    /// Returns `prim` with `xformOp:transform` set (or replaced) to `matrix`.
    static func settingTransform(_ prim: Prim, to matrix: [Double]) -> Prim {
        var copy = prim
        let attr = Attribute(name: transformAttributeName, value: .matrix4(matrix))
        if let i = copy.attributes.firstIndex(where: { $0.name == transformAttributeName }) {
            copy.attributes[i] = attr
        } else {
            copy.attributes.append(attr)
        }
        return copy
    }
}

/// Moves a prim under a new parent while preserving its **world** transform:
/// the prim's local `xformOp:transform` is recomputed so it lands in the same
/// place on screen (PRD §5.3 "reparent (world-transform preserving)").
public struct ReparentPrimCommand: EditCommand {
    /// The prim as it was at its old location (for undo).
    public let original: Prim
    public let oldParent: PrimPath?
    public let oldIndex: Int
    /// The prim rewritten for its new location, with adjusted local transform.
    public let moved: Prim
    public let newParent: PrimPath?
    public let newIndex: Int

    public var label: String { "Reparent \(original.name)" }

    /// Builds the command by reading the current stage, or returns `nil` if the
    /// move is invalid (missing prim, no-op, or a cycle).
    public static func make(path: PrimPath,
                            under newParent: PrimPath?,
                            in stage: any USDStageProtocol) -> ReparentPrimCommand? {
        guard !path.isRoot, let original = stage.prim(at: path) else { return nil }
        let oldParent = StructureSupport.parent(of: path)
        // No-op and cycle guards.
        if newParent == oldParent { return nil }
        if let newParent, newParent == path || path.isAncestor(of: newParent) { return nil }
        if let newParent, stage.prim(at: newParent) == nil { return nil }
        guard let oldIndex = StructureSupport.index(of: path, in: stage) else { return nil }

        let name = StructureSupport.uniqueName(
            base: path.name, amongst: StructureSupport.siblingNames(of: newParent, in: stage))
        guard let newPath = StructureSupport.childPath(parent: newParent, name: name) else { return nil }

        // World-preserving local transform: newLocal = oldWorld · inverse(newParentWorld).
        let oldWorld = stage.worldMatrix(at: path)
        let newParentWorld = newParent.map { stage.worldMatrix(at: $0) } ?? Matrix4.identity
        let newLocal = Matrix4.multiply(oldWorld, Matrix4.inverse(newParentWorld) ?? Matrix4.identity)

        var moved = original
        InMemoryStage.reparentPaths(&moved, to: newPath)
        moved = StructureSupport.settingTransform(moved, to: newLocal)
        let newIndex = StructureSupport.children(of: newParent, in: stage).count

        return ReparentPrimCommand(original: original, oldParent: oldParent, oldIndex: oldIndex,
                                   moved: moved, newParent: newParent, newIndex: newIndex)
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.removePrim(path: original.path))
        try stage.apply(.insertPrim(parent: newParent, index: newIndex, prim: moved))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.removePrim(path: moved.path))
        try stage.apply(.insertPrim(parent: oldParent, index: oldIndex, prim: original))
    }
}

/// Duplicates a prim (and its subtree) as a sibling with a unique name. The copy
/// keeps the original's local transform, so it lands exactly on top.
public struct DuplicatePrimCommand: EditCommand {
    public let copy: Prim
    public let parent: PrimPath?
    public let index: Int

    public var label: String { "Duplicate \(copy.name)" }

    /// The path of the created duplicate (for selecting it after the edit).
    public var duplicatePath: PrimPath { copy.path }

    public static func make(path: PrimPath, in stage: any USDStageProtocol) -> DuplicatePrimCommand? {
        guard !path.isRoot, let original = stage.prim(at: path),
              let index = StructureSupport.index(of: path, in: stage) else { return nil }
        let parent = StructureSupport.parent(of: path)
        let name = StructureSupport.uniqueName(
            base: path.name, amongst: StructureSupport.siblingNames(of: parent, in: stage))
        guard let newPath = StructureSupport.childPath(parent: parent, name: name) else { return nil }

        var copy = original
        InMemoryStage.reparentPaths(&copy, to: newPath)
        return DuplicatePrimCommand(copy: copy, parent: parent, index: index + 1)
    }

    public func execute(on stage: any USDStageMutable) throws {
        try stage.apply(.insertPrim(parent: parent, index: index, prim: copy))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.removePrim(path: copy.path))
    }
}

/// Groups sibling prims under a new `Xform`. The group carries an identity
/// transform, so grouped children keep their local (and therefore world)
/// transforms unchanged (PRD §5.3 "group prims").
public struct GroupPrimsCommand: EditCommand {
    /// Originals paired with their sibling index, ascending (for undo).
    public let originals: [(prim: Prim, index: Int)]
    public let parent: PrimPath?
    public let group: Prim
    public let groupIndex: Int

    public var label: String { "Group \(originals.count) Prims" }

    public var groupPath: PrimPath { group.path }

    /// Builds a group from `paths`. All must be existing siblings; returns `nil`
    /// otherwise. The group is inserted where the first selected sibling was.
    public static func make(paths: [PrimPath],
                            named groupName: String = "Group",
                            in stage: any USDStageProtocol) -> GroupPrimsCommand? {
        guard let first = paths.first else { return nil }
        let parent = StructureSupport.parent(of: first)
        // Uniqueness + shared-parent + existence checks.
        var seen = Set<PrimPath>()
        var collected: [(Prim, Int)] = []
        for path in paths {
            guard seen.insert(path).inserted,
                  StructureSupport.parent(of: path) == parent,
                  let prim = stage.prim(at: path),
                  let index = StructureSupport.index(of: path, in: stage) else { return nil }
            collected.append((prim, index))
        }
        collected.sort { $0.1 < $1.1 }
        let groupIndex = collected.first!.1

        var siblings = StructureSupport.siblingNames(of: parent, in: stage)
        // The soon-to-be-grouped names free up, but keeping them reserved is
        // harmless and avoids colliding with a child we're about to nest.
        let name = StructureSupport.uniqueName(base: groupName, amongst: siblings)
        siblings.insert(name)
        guard let groupPath = StructureSupport.childPath(parent: parent, name: name) else { return nil }

        // Nest each original under the group, preserving local transforms.
        let children: [Prim] = collected.map { (prim, _) in
            var child = prim
            if let childPath = groupPath.appending(prim.path.name) {
                InMemoryStage.reparentPaths(&child, to: childPath)
            }
            return child
        }
        let group = Prim(path: groupPath, typeName: "Xform", children: children)

        return GroupPrimsCommand(originals: collected.map { (prim: $0.0, index: $0.1) },
                                 parent: parent, group: group, groupIndex: groupIndex)
    }

    public func execute(on stage: any USDStageMutable) throws {
        for (prim, _) in originals {
            try stage.apply(.removePrim(path: prim.path))
        }
        try stage.apply(.insertPrim(parent: parent, index: groupIndex, prim: group))
    }

    public func undo(on stage: any USDStageMutable) throws {
        try stage.apply(.removePrim(path: group.path))
        for (prim, index) in originals {   // ascending — restores original order
            try stage.apply(.insertPrim(parent: parent, index: index, prim: prim))
        }
    }
}
