import Foundation

/// A stage view that pays for one depth-first traversal up front and then answers
/// `allPrims()` and `prim(at:)` from precomputed storage.
///
/// The unindexed defaults on `USDStageProtocol` re-walk the whole hierarchy on
/// every call, allocating a fresh array each time. That is fine for a handful of
/// prims and quadratic-ish in practice for consumers that ask repeatedly — the
/// ARKit validation profile alone asked six times per pass, and enterprise CAD
/// assemblies routinely carry hundreds of thousands of prims.
///
/// Wrap once, share the wrapper:
///
/// ```swift
/// let indexed = IndexedStage(stage)
/// for rule in rules { rule.evaluate(stage: indexed) }  // one walk total
/// ```
///
/// `IndexedStage` is an immutable snapshot of the stage it was built from. It
/// deliberately does not observe mutations — rebuild it after applying a
/// `StageMutation`. Building is O(n); lookups are O(1).
public struct IndexedStage: USDStageProtocol, Sendable {
    public let sourceURL: URL?
    public let metadata: StageMetadata
    public let rootPrims: [Prim]

    /// Depth-first traversal, computed once at construction.
    private let flattened: [Prim]
    /// Absolute path → prim. Built from `flattened`, so it agrees with it exactly.
    private let byPath: [PrimPath: Prim]

    /// Builds an index over `stage`. Wrapping an `IndexedStage` again is
    /// harmless but pointless — it rebuilds the same tables.
    public init(_ stage: any USDStageProtocol) {
        self.sourceURL = stage.sourceURL
        self.metadata = stage.metadata
        self.rootPrims = stage.rootPrims

        let all = stage.allPrims()
        self.flattened = all

        // A well-formed stage has unique paths. If a malformed one repeats a
        // path, keep the first occurrence so lookups match the traversal order
        // the unindexed `prim(at:)` would have returned.
        var table = [PrimPath: Prim](minimumCapacity: all.count)
        for prim in all where table[prim.path] == nil {
            table[prim.path] = prim
        }
        self.byPath = table
    }

    public func allPrims() -> [Prim] { flattened }

    public func prim(at path: PrimPath) -> Prim? { byPath[path] }
}

extension USDStageProtocol {
    /// Returns an `IndexedStage` over this stage, or `self` when it is already
    /// indexed. Lets a consumer opt into O(1) lookups without knowing whether an
    /// upstream caller already paid for the traversal.
    public func indexed() -> any USDStageProtocol {
        self as? IndexedStage ?? IndexedStage(self)
    }
}
