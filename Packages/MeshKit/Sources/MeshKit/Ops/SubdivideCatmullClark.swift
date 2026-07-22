import Foundation
import simd

/// Catmull-Clark subdivision: one level replaces every n-gon with n quads by
/// introducing a face point (the face centroid), an edge point per edge, and a
/// smoothed position for every original vertex. Repeated `levels` times.
///
/// Unlike `BevelEdges`/`ExtrudeFaces`, this is a genuinely *whole-mesh* op: it
/// consumes the entire face set and is valid on every build primitive — the
/// closed solids (box/cylinder/cone/sphere) and the open plane alike. It is the
/// refinement the sculpt pipeline needs to smooth the faceted, "lumpy" look of
/// low-poly stock into rounded subdivision surfaces.
///
/// Positions follow the standard Catmull-Clark masks:
/// - Face point `F` = centroid of the face.
/// - Interior edge point = average of the edge's two endpoints and the two
///   incident face points; boundary edge point = the edge midpoint.
/// - Interior vertex (valence n) = (Q + 2R + (n−3)P) / n, where Q is the mean
///   of incident face points and R is the mean of incident edge midpoints.
/// - Boundary vertex = ¾P + ⅛(e₁ + e₂) over its two boundary neighbours (crease
///   rule); a vertex without exactly two boundary neighbours is left in place.
///
/// Winding is preserved: face i of the original loop becomes the quad
/// [Vᵢ, edgePoint(Vᵢ,Vᵢ₊₁), facePoint, edgePoint(Vᵢ₋₁,Vᵢ)]. GeomSubset
/// membership carries from each original face to all of its child quads.
///
/// Per level, for a mesh with V vertices, E edges, F faces and C total face
/// corners (Σ loop.count): ΔV = E + F, ΔE = E + C, ΔF = C − F.
public enum SubdivideCatmullClark: MeshOp {
    public static let name = "Subdivide"

    public struct Params: Sendable {
        /// Number of subdivision levels to apply (≥ 1).
        public var levels: Int
        public init(levels: Int = 1) { self.levels = levels }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard case .faces(let faces) = selection, !faces.isEmpty else {
            throw MeshOpError.emptySelection
        }
        // Subdivision is inherently global — a partial selection would leave
        // T-junctions (non-manifold seams) at the boundary of the subdivided
        // region, so require the whole face set.
        guard faces == Set(mesh.faceLoops.keys) else {
            throw MeshOpError.preconditionFailed("Catmull-Clark subdivides the whole mesh; select all faces")
        }
        guard params.levels >= 1 else {
            throw MeshOpError.preconditionFailed("levels must be ≥ 1")
        }

        var current = mesh
        for _ in 0..<params.levels {
            current = try subdivideOnce(current)
        }
        return MeshOpResult(
            mesh: current,
            resultSelection: .faces(Set(current.faceLoops.keys)),
            delta: TopologyDelta(
                vertices: current.vertexCount - mesh.vertexCount,
                edges: current.edgeCount - mesh.edgeCount,
                faces: current.faceCount - mesh.faceCount))
    }

    /// One Catmull-Clark level, verified against its own predicted delta.
    private static func subdivideOnce(_ mesh: HalfEdgeMesh) throws -> HalfEdgeMesh {
        let edgeFaces = mesh.edgeFaceMap
        let vertexFaces = mesh.vertexFaceMap
        let boundary = mesh.boundaryEdges

        // Face points: centroid of every face.
        var facePoint: [FaceID: SIMD3<Double>] = [:]
        facePoint.reserveCapacity(mesh.faceCount)
        for f in mesh.faceOrder { facePoint[f] = mesh.faceCentroid(f) }

        var out = HalfEdgeMesh()

        // Emit the new geometry into `out`, remembering each new vertex ID.
        var faceVertex: [FaceID: VertexID] = [:]
        for f in mesh.faceOrder { faceVertex[f] = out.addVertex(facePoint[f]!) }

        // Edge points, shared by both incident faces.
        var edgeVertex: [EdgeKey: VertexID] = [:]
        edgeVertex.reserveCapacity(edgeFaces.count)
        for (edge, adj) in edgeFaces {
            let pa = mesh.positions[edge.a]!, pb = mesh.positions[edge.b]!
            let pos: SIMD3<Double>
            if boundary.contains(edge) {
                pos = (pa + pb) / 2
            } else {
                let f0 = facePoint[adj[0]]!, f1 = facePoint[adj[1]]!
                pos = (pa + pb + f0 + f1) / 4
            }
            edgeVertex[edge] = out.addVertex(pos)
        }

        // Original vertices, smoothed. Boundary vertices use the crease rule.
        var boundaryNeighbours: [VertexID: [VertexID]] = [:]
        for edge in boundary {
            boundaryNeighbours[edge.a, default: []].append(edge.b)
            boundaryNeighbours[edge.b, default: []].append(edge.a)
        }
        var vertexVertex: [VertexID: VertexID] = [:]
        for v in mesh.vertexOrder {
            let p = mesh.positions[v]!
            let newPos: SIMD3<Double>
            if let nbrs = boundaryNeighbours[v] {
                if nbrs.count == 2 {
                    newPos = p * 0.75 + (mesh.positions[nbrs[0]]! + mesh.positions[nbrs[1]]!) * 0.125
                } else {
                    // coverage:disable — unreachable on a manifold input: a boundary
                    // vertex of a valid mesh lies on exactly one boundary loop, so it
                    // has exactly two boundary-edge neighbours. A vertex with a
                    // different count would already be a non-manifold junction that
                    // `MeshInvariants` rejects. Kept as a defensive fixed-point.
                    newPos = p
                    // coverage:enable
                }
            } else {
                let incident = vertexFaces[v] ?? []
                let n = incident.count
                // Sum of incident face points.
                var q = SIMD3<Double>()
                for f in incident { q += facePoint[f]! }
                q /= Double(n)
                // Mean of incident edge midpoints.
                var r = SIMD3<Double>()
                var edgeCount = 0
                for (edge, _) in edgeFaces where edge.contains(v) {
                    r += (mesh.positions[edge.a]! + mesh.positions[edge.b]!) / 2
                    edgeCount += 1
                }
                r /= Double(edgeCount)
                newPos = (q + r * 2 + p * Double(n - 3)) / Double(n)
            }
            vertexVertex[v] = out.addVertex(newPos)
        }

        // Build the child quads and carry subset membership.
        var childFaces: [FaceID: [FaceID]] = [:]
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            let n = loop.count
            let fp = faceVertex[f]!
            var kids: [FaceID] = []
            for i in 0..<n {
                let vi = loop[i]
                let next = loop[(i + 1) % n]
                let prev = loop[(i + n - 1) % n]
                let epNext = edgeVertex[EdgeKey(vi, next)]!
                let epPrev = edgeVertex[EdgeKey(prev, vi)]!
                kids.append(out.addFace([vertexVertex[vi]!, epNext, fp, epPrev]))
            }
            childFaces[f] = kids
        }
        for (name, members) in mesh.subsets {
            for f in members {
                for kid in childFaces[f] ?? [] { out.addFaceToSubset(kid, subset: name) }
            }
        }

        let c = mesh.faceLoops.values.reduce(0) { $0 + $1.count }
        let predicted = TopologyDelta(
            vertices: mesh.edgeCount + mesh.faceCount,
            edges: mesh.edgeCount + c,
            faces: c - mesh.faceCount)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return out
    }
}
