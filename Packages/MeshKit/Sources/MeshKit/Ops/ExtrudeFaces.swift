import Foundation

/// Region extrude along the averaged (area-weighted) normal or an explicit axis.
/// Predicted delta (spec table): V += boundaryV, E += boundaryE + boundaryV,
/// F += boundaryE.
public enum ExtrudeFaces: MeshOp {
    public static let name = "Extrude"

    public struct Params: Sendable {
        public enum Direction: Sendable {
            case averagedNormal
            case axis(SIMD3<Double>)
        }
        public var distance: Double
        public var direction: Direction
        public init(distance: Double, direction: Direction = .averagedNormal) {
            self.distance = distance
            self.direction = direction
        }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard case .faces(let region) = selection, !region.isEmpty else {
            throw MeshOpError.emptySelection
        }
        for f in region where mesh.faceLoops[f] == nil {
            throw MeshOpError.unknownComponent("face \(f.rawValue)")
        }
        guard params.distance != 0 else {
            throw MeshOpError.preconditionFailed("extrude distance must be non-zero")
        }

        let edgeFaces = mesh.edgeFaceMap
        for (e, faces) in edgeFaces where faces.count > 2 && faces.contains(where: region.contains) {
            throw MeshOpError.nonManifoldRegion("edge (\(e.a.rawValue),\(e.b.rawValue)) borders \(faces.count) faces")
        }

        // Region-boundary edges: exactly one adjacent face is selected.
        var boundaryEdgeSet = Set<EdgeKey>()
        for (e, faces) in edgeFaces {
            let selectedCount = faces.filter(region.contains).count
            if selectedCount == 1 { boundaryEdgeSet.insert(e) }
        }
        var boundaryVerts = Set<VertexID>()
        for e in boundaryEdgeSet { boundaryVerts.insert(e.a); boundaryVerts.insert(e.b) }

        // Bowtie precondition: a vertex shared by both selected and unselected
        // faces must lie on a region-boundary edge; otherwise topology is ambiguous.
        let vertexFaces = mesh.vertexFaceMap
        var regionVerts = Set<VertexID>()
        for f in region { regionVerts.formUnion(mesh.faceLoops[f]!) }
        for v in regionVerts where !boundaryVerts.contains(v) {
            if (vertexFaces[v] ?? []).contains(where: { !region.contains($0) }) {
                throw MeshOpError.preconditionFailed(
                    "vertex \(v.rawValue) links the region to outside faces without a shared boundary edge (bowtie)")
            }
        }

        // Offset vector.
        let dir: SIMD3<Double>
        switch params.direction {
        case .axis(let axis):
            guard simd_length(axis) > MeshInvariants.epsilon else {
                throw MeshOpError.preconditionFailed("extrude axis is zero-length")
            }
            dir = simd_normalize(axis)
        case .averagedNormal:
            var n = SIMD3<Double>()
            for f in region { n += mesh.faceNormalArea(f) }
            guard simd_length(n) > MeshInvariants.epsilon else {
                throw MeshOpError.preconditionFailed("region normals cancel out; pass an explicit axis")
            }
            dir = simd_normalize(n)
        }
        let offset = dir * params.distance

        // A boundary edge parallel to the extrude direction would sweep a
        // zero-area side quad — fail with an actionable precondition instead
        // of a post-op invariant violation.
        for e in boundaryEdgeSet {
            let along = mesh.positions[e.b]! - mesh.positions[e.a]!
            if simd_length(simd_cross(along, dir)) <= MeshInvariants.epsilon {
                throw MeshOpError.preconditionFailed(
                    "boundary edge (\(e.a.rawValue),\(e.b.rawValue)) is parallel to the extrude direction; its side face would be degenerate — pick a different axis")
            }
        }

        var out = mesh

        // Duplicate boundary vertices; interior region verts just move.
        var duplicate: [VertexID: VertexID] = [:]
        for v in boundaryVerts.sorted() {
            duplicate[v] = out.addVertex(mesh.positions[v]! + offset)
        }
        for v in regionVerts.sorted() where !boundaryVerts.contains(v) {
            out.setPosition(mesh.positions[v]! + offset, for: v)
        }

        // Retarget cap faces onto the duplicated verts.
        for f in region.sorted() {
            let loop = mesh.faceLoops[f]!
            let newLoop = loop.map { duplicate[$0] ?? $0 }
            if newLoop != loop { out.replaceLoop(newLoop, for: f) }
        }

        // Side quads. For each boundary edge, orient by the selected cap face's
        // traversal a→b: quad [a, b, b′, a′] keeps winding consistent with both
        // the outside neighbor and the lifted cap.
        for e in boundaryEdgeSet.sorted(by: { ($0.a, $0.b) < ($1.a, $1.b) }) {
            guard let capFace = edgeFaces[e]?.first(where: region.contains) else { continue }
            let loop = mesh.faceLoops[capFace]!
            var a = e.a, b = e.b
            for i in loop.indices {
                let u = loop[i], w = loop[(i + 1) % loop.count]
                if EdgeKey(u, w) == e { a = u; b = w; break }
            }
            let side = out.addFace([a, b, duplicate[b]!, duplicate[a]!])
            // Invariant 6: side walls inherit the cap face's subset (material).
            for (name, members) in mesh.subsets where members.contains(capFace) {
                out.addFaceToSubset(side, subset: name)
            }
        }

        let predicted = TopologyDelta(vertices: boundaryVerts.count,
                                      edges: boundaryEdgeSet.count + boundaryVerts.count,
                                      faces: boundaryEdgeSet.count)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return MeshOpResult(mesh: out, resultSelection: .faces(region), delta: predicted)
    }
}

extension EdgeKey {
    static func < (l: EdgeKey, r: EdgeKey) -> Bool { (l.a, l.b) < (r.a, r.b) }
}
