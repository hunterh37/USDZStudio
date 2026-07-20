import Foundation
import simd

/// Renderable geometry for one prim, in the viewport's own terms: positions
/// plus per-face vertex-index loops (n-gons allowed, fan-triangulated on the
/// GPU side by `MeshFlattener`). Mirrors `EditedMeshData`'s representation so
/// the component-edit path and the scene-graph path speak one geometry
/// language.
public struct ViewportMeshData: Equatable, Sendable {
    public var positions: [SIMD3<Float>]
    public var faceLoops: [[Int]]

    public init(positions: [SIMD3<Float>], faceLoops: [[Int]]) {
        self.positions = positions
        self.faceLoops = faceLoops
    }
}

/// One prim as the viewport needs to draw it. Pure data — no RealityKit — so
/// the projection from the stage stays unit-testable and platform-free.
///
/// `path` is the full prim path ("/Rig/Panel") and is the identity used for
/// every diff decision; entity *names* are never load-bearing here (two prims
/// at different depths may share a name).
public struct ViewportPrimNode: Equatable, Sendable {
    public var path: String
    /// Local transform relative to the parent prim.
    public var transform: float4x4
    /// Geometry, when this prim is renderable. `nil` for pure grouping prims
    /// (Xform/Scope), which still exist as entities so children inherit their
    /// transform.
    public var mesh: ViewportMeshData?
    /// Hidden/deactivated prims stay in the graph but render disabled, so undo
    /// and "show disabled" can bring them back without a rebuild.
    public var isEnabled: Bool

    public init(path: String, transform: float4x4 = matrix_identity_float4x4,
                mesh: ViewportMeshData? = nil, isEnabled: Bool = true) {
        self.path = path
        self.transform = transform
        self.mesh = mesh
        self.isEnabled = isEnabled
    }

    /// The parent prim's path, or `nil` for a root prim. Derived from `path`
    /// rather than stored so a node can never disagree with its own identity.
    public var parentPath: String? {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return nil }
        return String(path[path.startIndex..<slash])
    }

    /// Depth below the pseudo-root: "/Cube" is 1, "/Cube/Geo" is 2. Drives
    /// parent-before-child insert ordering.
    public var depth: Int {
        path.reduce(into: 0) { count, ch in if ch == "/" { count += 1 } }
    }
}

/// The full set of prims the viewport should be drawing right now, keyed by
/// prim path. Order-independent by construction: the diff derives ordering
/// from path depth, so callers never have to hand-sort.
public struct ViewportScene: Equatable, Sendable {
    public var nodes: [String: ViewportPrimNode]

    public init(nodes: [String: ViewportPrimNode] = [:]) {
        self.nodes = nodes
    }

    public init(_ nodes: [ViewportPrimNode]) {
        self.nodes = Dictionary(nodes.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var isEmpty: Bool { nodes.isEmpty }

    public subscript(path: String) -> ViewportPrimNode? { nodes[path] }
}

/// A single change to apply to the live RealityKit entity tree.
///
/// Split by *cost*: swapping a transform or an enablement flag is a property
/// write, while geometry changes rebuild a `MeshResource`. Keeping them
/// distinct is what makes a gizmo drag cheap — it emits only
/// `.updateTransform` per frame, never a re-mesh.
public enum SceneGraphOperation: Equatable, Sendable {
    /// Create an entity for this prim and parent it under `parentPath`
    /// (or the scene root). Emitted parent-before-child.
    case insert(ViewportPrimNode)
    /// Tear down this prim's entity and its whole subtree. Emitted only for
    /// the subtree root — descendants leave with it.
    case remove(path: String)
    /// Geometry changed (or appeared/vanished): rebuild the mesh resource.
    case updateMesh(path: String, mesh: ViewportMeshData?)
    case updateTransform(path: String, transform: float4x4)
    case setEnabled(path: String, isEnabled: Bool)
}

/// Turns "what the viewport is drawing" + "what the stage now says" into the
/// minimal list of entity-tree edits between them.
///
/// This is the seam that lets the file stay a *seed* rather than the source of
/// truth: the file load establishes an initial scene, and every subsequent
/// authored change — insert from the library, delete, isolate, gizmo drag —
/// arrives as a diff against it. Pure and total, so it can be exhaustively
/// tested without an `ARView`.
public enum SceneGraphDiff {

    /// Operations that carry `old` to `new`, ordered so they can be applied
    /// blindly in sequence:
    ///
    /// 1. removals, deepest-first (a child never outlives its parent);
    /// 2. inserts, shallowest-first (a parent always exists before its child);
    /// 3. in-place updates on prims common to both scenes.
    public static func operations(from old: ViewportScene, to new: ViewportScene) -> [SceneGraphOperation] {
        var ops: [SceneGraphOperation] = []

        // 1. Removals. Only subtree roots are emitted: if a prim's parent is
        //    also going away, removing the parent takes this one with it, and
        //    emitting both would double-remove.
        let removedPaths = Set(old.nodes.keys).subtracting(new.nodes.keys)
        let removalRoots = removedPaths.filter { path in
            guard let parent = old.nodes[path]?.parentPath else { return true }
            return !removedPaths.contains(parent)
        }
        for path in removalRoots.sorted() {
            ops.append(.remove(path: path))
        }

        // 2. Inserts, parent-before-child. Sorting by depth then path keeps the
        //    order deterministic (tests, and golden-image stability, depend on
        //    a stable sibling order).
        let insertedPaths = Set(new.nodes.keys).subtracting(old.nodes.keys)
        let inserted = insertedPaths.compactMap { new.nodes[$0] }
            .sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
        for node in inserted {
            ops.append(.insert(node))
        }

        // 3. Updates on survivors, in a stable path order.
        for path in Set(old.nodes.keys).intersection(new.nodes.keys).sorted() {
            guard let before = old.nodes[path], let after = new.nodes[path] else { continue }
            if before.mesh != after.mesh {
                ops.append(.updateMesh(path: path, mesh: after.mesh))
            }
            if before.transform != after.transform {
                ops.append(.updateTransform(path: path, transform: after.transform))
            }
            if before.isEnabled != after.isEnabled {
                ops.append(.setEnabled(path: path, isEnabled: after.isEnabled))
            }
        }

        return ops
    }
}
