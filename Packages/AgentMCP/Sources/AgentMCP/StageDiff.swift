import Foundation
import USDCore

/// Synthesized structural diff between two stage snapshots.
///
/// `CommandStack.run` returns only the verb label; commands don't expose
/// their mutation lists. Every mutating tool therefore snapshots the stage
/// before/after and reports this diff so the agent can reason about exactly
/// what changed (docs/AGENT_MCP_PLAN.md §3 — "`diff` is the StageMutation set").
public struct StageDiff: Sendable, Hashable {
    public var addedPrims: [PrimPath] = []
    public var removedPrims: [PrimPath] = []
    /// Prims whose attributes, type, activation, visibility, variant
    /// selections, or relationships changed (path is the stable identity).
    public var modifiedPrims: [PrimPath] = []
    /// Attribute names changed per modified prim path.
    public var changedAttributes: [PrimPath: [String]] = [:]
    public var metadataChanged = false

    public init() {}

    public var isEmpty: Bool {
        addedPrims.isEmpty && removedPrims.isEmpty && modifiedPrims.isEmpty && !metadataChanged
    }

    /// Compare two snapshots by flattened prim path.
    public static func compute(before: StageSnapshot, after: StageSnapshot) -> StageDiff {
        var diff = StageDiff()
        let beforeMap = index(of: before)
        let afterMap = index(of: after)

        diff.addedPrims = afterMap.keys.filter { beforeMap[$0] == nil }.sorted()
        diff.removedPrims = beforeMap.keys.filter { afterMap[$0] == nil }.sorted()

        for (path, old) in beforeMap {
            guard let new = afterMap[path] else { continue }
            if !equivalent(old, new) {
                diff.modifiedPrims.append(path)
                let changed = changedAttributeNames(old: old, new: new)
                if !changed.isEmpty { diff.changedAttributes[path] = changed }
            }
        }
        diff.modifiedPrims.sort()
        diff.metadataChanged = before.metadata != after.metadata
        return diff
    }

    public var asJSON: JSONValue {
        var perPrim: [String: JSONValue] = [:]
        for (path, names) in changedAttributes {
            perPrim[path.description] = .array(names.map { .string($0) })
        }
        return .object([
            "added": .array(addedPrims.map { .string($0.description) }),
            "removed": .array(removedPrims.map { .string($0.description) }),
            "modified": .array(modifiedPrims.map { .string($0.description) }),
            "changedAttributes": .object(perPrim),
            "metadataChanged": .bool(metadataChanged),
        ])
    }

    // MARK: - Internals

    private static func index(of snapshot: StageSnapshot) -> [PrimPath: Prim] {
        var map: [PrimPath: Prim] = [:]
        for root in snapshot.rootPrims {
            for prim in root.flattened() { map[prim.path] = prim }
        }
        return map
    }

    /// Prim equality ignoring children (child changes surface at their own paths).
    private static func equivalent(_ a: Prim, _ b: Prim) -> Bool {
        a.typeName == b.typeName
            && a.isActive == b.isActive
            && a.visibility == b.visibility
            && a.attributes == b.attributes
            && a.relationships == b.relationships
            && a.metadata == b.metadata
            && a.variantSets == b.variantSets
    }

    private static func changedAttributeNames(old: Prim, new: Prim) -> [String] {
        let oldByName = Dictionary(old.attributes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newByName = Dictionary(new.attributes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var names = Set<String>()
        for (name, attr) in newByName where oldByName[name] != attr { names.insert(name) }
        for name in oldByName.keys where newByName[name] == nil { names.insert(name) }
        return names.sorted()
    }
}
