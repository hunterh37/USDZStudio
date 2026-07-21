import Foundation

/// Give an open surface thickness by generating an offset inner shell and
/// bridging the boundary into one closed manifold (specs/mesh-editing.md,
/// Phase 8 modeling).
///
/// The classic "solidify" / shell modifier: duplicate every face offset by
/// `thickness` along the reversed vertex normal, reverse its winding so it faces
/// inward, then stitch the outer boundary to the inner boundary with a quad wall
/// per boundary edge. A disk-topology surface becomes a sphere-topology shell.
///
/// Strict v1 preconditions (fail loudly, per the op contract):
/// - the selection is the whole mesh (`.faces` covering every face)
/// - the surface is manifold (every edge borders ≤ 2 faces)
/// - the surface is *open* — it must have at least one boundary edge to bridge;
///   a closed mesh has nothing to stitch and would self-intersect on offset
/// - `thickness` is strictly positive
///
/// Predicted delta: one new vertex per original vertex (the inner shell), one
/// new face per original face plus one bridge quad per boundary edge, and one
/// new edge per original edge (the inner copy) plus one vertical edge per
/// boundary vertex. For a single boundary loop this doubles the Euler
/// characteristic (a disk, χ = 1, becomes a closed shell, χ = 2).
public enum Solidify: MeshOp {
    public static let name = "Solidify"

    public struct Params: Sendable {
        /// Shell thickness in world units (offset distance along −normal).
        public var thickness: Double
        public init(thickness: Double) { self.thickness = thickness }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard case .faces(let faces) = selection, !faces.isEmpty else {
            throw MeshOpError.emptySelection
        }
        guard faces == Set(mesh.faceOrder) else {
            throw MeshOpError.preconditionFailed(
                "solidify v1 shells the whole mesh; select every face (got \(faces.count) of \(mesh.faceCount))")
        }
        guard params.thickness > MeshInvariants.epsilon else {
            throw MeshOpError.preconditionFailed(
                "solidify thickness must be positive; got \(params.thickness)")
        }

        let edgeFaces = mesh.edgeFaceMap
        if let nonManifold = edgeFaces.first(where: { $0.value.count > 2 }) {
            throw MeshOpError.nonManifoldRegion(
                "edge (\(nonManifold.key.a.rawValue),\(nonManifold.key.b.rawValue)) borders \(nonManifold.value.count) faces")
        }
        let boundary = edgeFaces.filter { $0.value.count == 1 }
        guard !boundary.isEmpty else {
            throw MeshOpError.preconditionFailed(
                "solidify needs an open surface; this mesh has no boundary edge to bridge")
        }

        // Outward area-weighted vertex normals (Newell face normals summed over
        // the incident faces, then normalized).
        let vertexFaces = mesh.vertexFaceMap
        var normals: [VertexID: SIMD3<Double>] = [:]
        for v in mesh.vertexOrder {
            var n = SIMD3<Double>()
            for f in vertexFaces[v] ?? [] { n += mesh.faceNormalArea(f) }
            normals[v] = simd_normalize(n)
        }

        var out = mesh

        // Inner shell vertices, offset along −normal.
        var inner: [VertexID: VertexID] = [:]
        for v in mesh.vertexOrder {
            inner[v] = out.addVertex(mesh.positions[v]! - params.thickness * normals[v]!)
        }

        // Inner faces: reversed original loops (face inward) over the inner verts.
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            let innerLoop = loop.reversed().map { inner[$0]! }
            let uvs = mesh.faceCornerUVs[f].map { Array($0.reversed()) }
            let added = out.addFace(innerLoop, uvs: uvs)
            for (name, members) in mesh.subsets where members.contains(f) {
                out.addFaceToSubset(added, subset: name)
            }
        }

        // Bridge each boundary edge, oriented as its single incident face
        // traverses it, into an outward-facing wall quad.
        var boundaryVertices = Set<VertexID>()
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            for i in loop.indices {
                let u = loop[i], w = loop[(i + 1) % loop.count]
                guard boundary[EdgeKey(u, w)] != nil else { continue }
                boundaryVertices.insert(u)
                boundaryVertices.insert(w)
                // Outer face runs u→w, so the wall runs w→u on the shared edge to
                // keep winding consistent; the inner edge closes the quad.
                out.addFace([w, u, inner[u]!, inner[w]!])
            }
        }

        let predicted = TopologyDelta(
            vertices: mesh.vertexCount,
            edges: mesh.edgeCount + boundaryVertices.count,
            faces: mesh.faceCount + boundary.count)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)

        let shellFaces = Set(out.faceOrder.suffix(mesh.faceCount + boundary.count))
        return MeshOpResult(mesh: out, resultSelection: .faces(shellFaces), delta: predicted)
    }
}
