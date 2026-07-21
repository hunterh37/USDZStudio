import Foundation

/// Reflect the whole mesh across an axis-aligned plane, welding the vertices
/// that already lie on the plane (specs/mesh-editing.md, Phase 8 modeling).
///
/// This is the "mirror modifier" building block: model one half, mirror it, and
/// the seam vertices on the plane are shared rather than duplicated so the two
/// halves join into one manifold surface. Mirrored faces get reversed winding
/// so their normals stay outward-consistent with the originals.
///
/// Strict v1 preconditions (fail loudly, per the op contract):
/// - the selection is the whole mesh (`.faces` covering every face) — v1 mirrors
///   the entire mesh, not an arbitrary island, so the seam is well defined
/// - the plane must not pass *through* the mesh: every vertex lies on one closed
///   side of it (on-plane counts as either side). A crossing plane would fold
///   geometry onto itself.
/// - no face may lie entirely on the plane — mirroring it onto itself (reversed)
///   would produce a non-manifold self-overlap.
///
/// Predicted delta: one new vertex per off-plane vertex (on-plane vertices are
/// reused), one new face per original face, and one new edge per original edge
/// that is not fully on the plane (fully-on-plane edges are the welded seam and
/// are shared). Euler characteristic changes by `χ_before` — a plane that misses
/// the mesh doubles it into two shells, a plane on the open boundary welds it
/// shut.
public enum Mirror: MeshOp {
    public static let name = "Mirror"

    /// Axis-aligned mirror plane: the coordinate axis it is perpendicular to,
    /// plus the plane's position along that axis.
    public enum Axis: Sendable, CaseIterable { case x, y, z }

    public struct Params: Sendable {
        public var axis: Axis
        /// Plane position along `axis` (world units). Default 0 (through origin).
        public var coordinate: Double
        public init(axis: Axis, coordinate: Double = 0) {
            self.axis = axis
            self.coordinate = coordinate
        }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard case .faces(let faces) = selection, !faces.isEmpty else {
            throw MeshOpError.emptySelection
        }
        guard faces == Set(mesh.faceOrder) else {
            throw MeshOpError.preconditionFailed(
                "mirror v1 reflects the whole mesh; select every face (got \(faces.count) of \(mesh.faceCount))")
        }

        let k = axisIndex(params.axis)
        let plane = params.coordinate

        // Classify each vertex against the plane. `signed` is the displacement
        // along the mirror axis; |signed| ≤ epsilon means "on the plane".
        func signed(_ v: VertexID) -> Double { mesh.positions[v]![k] - plane }
        func onPlane(_ v: VertexID) -> Bool { abs(signed(v)) <= MeshInvariants.epsilon }

        // Plane must not cut through the mesh: all off-plane vertices share a side.
        var sawPositive = false, sawNegative = false
        for v in mesh.vertexOrder {
            let s = signed(v)
            if s > MeshInvariants.epsilon { sawPositive = true }
            else if s < -MeshInvariants.epsilon { sawNegative = true }
        }
        guard !(sawPositive && sawNegative) else {
            throw MeshOpError.preconditionFailed(
                "mirror plane intersects the mesh; all geometry must lie on one side of it")
        }

        // No face may sit entirely on the plane (it would mirror onto itself).
        for f in mesh.faceOrder where mesh.faceLoops[f]!.allSatisfy(onPlane) {
            throw MeshOpError.preconditionFailed(
                "face \(f.rawValue) lies on the mirror plane; it would overlap its own reflection")
        }

        var out = mesh

        // Reflect off-plane vertices to fresh IDs; reuse on-plane vertices (weld).
        var mapping: [VertexID: VertexID] = [:]
        var newVertices = 0
        for v in mesh.vertexOrder {
            if onPlane(v) {
                mapping[v] = v
            } else {
                var p = mesh.positions[v]!
                p[k] = 2 * plane - p[k]
                mapping[v] = out.addVertex(p)
                newVertices += 1
            }
        }

        // Mirror every face with reversed winding (reflection flips orientation,
        // so reversing the loop keeps the mirrored normal pointing outward).
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            let mirrored = loop.reversed().map { mapping[$0]! }
            let uvs = mesh.faceCornerUVs[f].map { Array($0.reversed()) }
            let added = out.addFace(mirrored, uvs: uvs)
            for (name, members) in mesh.subsets where members.contains(f) {
                out.addFaceToSubset(added, subset: name)
            }
        }

        // Edges fully on the plane are the welded seam (shared, not new).
        let seamEdges = mesh.edgeSet.filter { onPlane($0.a) && onPlane($0.b) }.count
        let predicted = TopologyDelta(vertices: newVertices,
                                      edges: mesh.edgeCount - seamEdges,
                                      faces: mesh.faceCount)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)

        let mirroredFaces = Set(out.faceOrder.suffix(mesh.faceCount))
        return MeshOpResult(mesh: out, resultSelection: .faces(mirroredFaces), delta: predicted)
    }

    static func axisIndex(_ axis: Axis) -> Int {
        switch axis {
        case .x: return 0
        case .y: return 1
        case .z: return 2
        }
    }
}
