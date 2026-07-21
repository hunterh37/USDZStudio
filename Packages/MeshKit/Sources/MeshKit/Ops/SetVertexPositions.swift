import Foundation

/// Absolute per-vertex position setting — the kernel primitive behind live
/// vertex dragging (specs/mesh-editing.md §Live vertex edit). Unlike
/// `TransformComponents` (a *relative* affine transform), this receives the
/// final target position for each vertex, computed by the interaction layer
/// (base position + proportional-falloff-weighted drag delta). Keeping the two
/// distinct keeps each op's contract clean and keeps proportional-edit / UI
/// concepts out of the pure kernel.
///
/// Topology is untouched (delta zero by construction); the shared post-op
/// invariant check still rejects moves that collapse a face to zero area or
/// otherwise break manifoldness.
public enum SetVertexPositions: MeshOp {
    public static let name = "SetVertexPositions"

    public struct Params: Sendable {
        /// Absolute target positions, keyed by the vertex to move. Only the
        /// listed vertices move; every other vertex is left byte-identical.
        public var positions: [VertexID: SIMD3<Double>]

        public init(positions: [VertexID: SIMD3<Double>]) {
            self.positions = positions
        }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard !params.positions.isEmpty else {
            throw MeshOpError.preconditionFailed("no vertex positions supplied — nothing to do")
        }

        // Fail loud on unknown targets so callers get a referential diagnostic
        // instead of a silent no-op.
        for v in params.positions.keys where mesh.positions[v] == nil {
            throw MeshOpError.unknownComponent("vertex \(v.rawValue)")
        }

        // Reject non-finite coordinates explicitly. A NaN passes BOTH `< lo`
        // and `> hi` range comparisons (every comparison against NaN is false),
        // so an unguarded NaN silently poisons downstream area/volume invariants
        // rather than tripping them — the same class of bug fixed in SculptKit's
        // SpecValidator (commit 0644b24). Guard at the boundary.
        for (v, p) in params.positions {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                throw MeshOpError.preconditionFailed(
                    "vertex \(v.rawValue) target has a non-finite coordinate")
            }
        }

        var out = mesh
        for v in params.positions.keys.sorted() {
            out.setPosition(params.positions[v]!, for: v)
        }

        let predicted = TopologyDelta(vertices: 0, edges: 0, faces: 0)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return MeshOpResult(mesh: out, resultSelection: selection, delta: predicted)
    }
}
