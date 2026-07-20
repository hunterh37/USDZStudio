import Foundation

/// Pure viewport selection navigation for part-level editing
/// (specs/editing-model.md, ROADMAP Milestone 3): drill-down / walk-up over the
/// prim hierarchy, plus the breadcrumb trail that shows where you are.
///
/// All logic is a pure function of the stage snapshot and the current
/// selection — no I/O, no RealityKit, no Python (see `specs/architecture.md`).
public enum PartSelection {

    // MARK: Drill-down

    /// Resolves the next selection when the user clicks a prim in the viewport,
    /// mimicking the Blender/Maya "click the object, click again to go deeper"
    /// idiom.
    ///
    /// A viewport pick reports the *deepest* pickable prim under the cursor
    /// (`leaf`) — usually a bare `Mesh` buried several levels down. But clicking
    /// a car should first select the whole car, not the mesh of one bolt. So:
    ///
    /// - If `current` is not on the ancestor chain of `leaf` (a fresh click on a
    ///   different object), select the **top-level** ancestor of `leaf` (the
    ///   depth-1 prim). First click grabs the whole object.
    /// - If `current` *is* on the chain and isn't the leaf itself, select the
    ///   next prim one level **deeper** toward the leaf. Each subsequent click on
    ///   the same object drills in.
    /// - If `current` already is the leaf, stay there (nothing deeper to pick).
    ///
    /// Returns `nil` only when `leaf` is the root path (nothing to select).
    public static func drillDown(picked leaf: PrimPath, from current: PrimPath?) -> PrimPath? {
        guard !leaf.isRoot else { return nil }
        // The chain from the top-level ancestor (depth 1) down to the leaf.
        let chain = ancestorChain(of: leaf)

        guard let current, current == leaf || current.isAncestor(of: leaf) else {
            // Fresh object (or nothing selected): grab the whole top-level prim.
            return chain.first
        }
        if current == leaf { return leaf }              // already as deep as we go
        // `current` sits on the chain above the leaf — step one level deeper.
        let nextDepth = current.depth + 1
        return chain.first { $0.depth == nextDepth } ?? leaf
    }

    /// Walks the selection **up** one level toward the root, returning the parent
    /// prim's path. Returns `nil` at a top-level prim (depth 1) or the root —
    /// there is nothing selectable above a scene-root object.
    public static func walkUp(from path: PrimPath) -> PrimPath? {
        guard path.depth > 1 else { return nil }
        return path.parent
    }

    /// The chain of ancestor paths of `leaf`, from the top-level prim (depth 1)
    /// down to and including `leaf`. Empty when `leaf` is the root.
    public static func ancestorChain(of leaf: PrimPath) -> [PrimPath] {
        guard !leaf.isRoot else { return [] }
        return (1...leaf.depth).map {
            PrimPath(validatedComponents: Array(leaf.components.prefix($0)))
        }
    }

    // MARK: Breadcrumb

    /// One hop in the breadcrumb bar: a prim's path, display name, and type.
    public struct Crumb: Hashable, Sendable, Identifiable {
        public var id: PrimPath { path }
        public var path: PrimPath
        public var name: String
        public var typeName: String

        public init(path: PrimPath, name: String, typeName: String) {
            self.path = path
            self.name = name
            self.typeName = typeName
        }
    }

    /// Builds the breadcrumb trail from the top-level prim down to `path`,
    /// resolving each hop's type against `stage`. Hops with no prim on the stage
    /// (a path that outran the tree) fall back to an empty type name but are kept
    /// so the trail stays contiguous. An empty array for the root path.
    public static func breadcrumb(to path: PrimPath, in stage: any USDStageProtocol) -> [Crumb] {
        ancestorChain(of: path).map { hop in
            Crumb(path: hop, name: hop.name, typeName: stage.prim(at: hop)?.typeName ?? "")
        }
    }
}
