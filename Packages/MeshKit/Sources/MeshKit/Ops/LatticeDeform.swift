import Foundation

/// Bake a lattice (FFD) cage's deformation into a mesh's vertex positions
/// (specs/mesh-editing.md §Lattice deformer). Unlike the component ops, a lattice
/// is an *object-level* deformer: it binds and moves **every** vertex through the
/// cage, regardless of the component selection (the selection identifies the mesh
/// prim, not a sub-region). Topology is untouched — delta is zero by construction
/// — so the shared post-op invariant check still rejects a cage that folds a face
/// to zero area or otherwise breaks manifoldness.
///
/// The op is pure: it re-binds against the mesh's current (rest) positions each
/// call, so it carries no cached state. The interactive layer may cache the
/// `LatticeBinding` across drag frames; this kernel does not depend on that.
public enum LatticeDeform: MeshOp {
    public static let name = "Lattice Deform"

    public struct Params: Sendable {
        /// The cage, with its control points already at their edited positions.
        public var cage: LatticeCage
        public init(cage: LatticeCage) { self.cage = cage }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        // Validate up front so a degenerate cage fails loudly rather than
        // dividing by ~0 in the local-coordinate solve.
        try params.cage.validate()

        let restPoints = mesh.vertexOrder.map { mesh.positions[$0]! }
        let binding = try params.cage.bind(points: restPoints)
        let deformed = params.cage.deform(binding)

        var out = mesh
        for (i, v) in mesh.vertexOrder.enumerated() {
            let p = deformed[i]
            // A NaN/Inf control point (or extrapolation blow-up) would pass both
            // range comparisons silently and poison the area/volume invariants —
            // guard at the boundary, matching SetVertexPositions.
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                throw MeshOpError.preconditionFailed(
                    "vertex \(v.rawValue) deformed to a non-finite position")
            }
            out.setPosition(p, for: v)
        }

        let predicted = TopologyDelta(vertices: 0, edges: 0, faces: 0)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return MeshOpResult(mesh: out, resultSelection: selection, delta: predicted)
    }
}
