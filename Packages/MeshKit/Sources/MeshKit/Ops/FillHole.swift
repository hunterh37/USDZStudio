import Foundation

/// Fan-triangulate one boundary loop, identified by any edge (or vertex) on it.
/// Delta (spec table): F += n−2, E += n−3, V += 0.
public enum FillHole: MeshOp {
    public static let name = "Fill"
    public struct Params: Sendable { public init() {} }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params = .init()) throws -> MeshOpResult {
        let edgeFaces = mesh.edgeFaceMap

        // Resolve a seed boundary edge from the selection.
        let seed: EdgeKey
        switch selection {
        case .edges(let edges):
            guard let e = edges.sorted(by: <).first else { throw MeshOpError.emptySelection }
            guard let faces = edgeFaces[e] else {
                throw MeshOpError.unknownComponent("edge (\(e.a.rawValue),\(e.b.rawValue))")
            }
            guard faces.count == 1 else {
                throw MeshOpError.preconditionFailed("selected edge is not a boundary edge")
            }
            seed = e
        case .vertices(let verts):
            guard let v = verts.sorted().first else { throw MeshOpError.emptySelection }
            // Deterministic seed choice: dictionary iteration order varies per
            // process, and redo must re-apply identically (spec §Undo & commands).
            let candidates = edgeFaces.filter { $0.key.contains(v) && $0.value.count == 1 }.keys
            guard let e = candidates.sorted(by: <).first else {
                throw MeshOpError.preconditionFailed("selected vertex is not on a boundary loop")
            }
            seed = e
        case .faces:
            throw MeshOpError.preconditionFailed("Fill Hole needs an edge or vertex on the hole boundary")
        }

        // Directed boundary half-edges: face traverses u→w, so the hole side
        // runs w→u. Following hole-side direction yields a loop whose winding
        // is consistent with the surrounding faces.
        var holeNext: [VertexID: VertexID] = [:]
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            for i in loop.indices {
                let u = loop[i], w = loop[(i + 1) % loop.count]
                if edgeFaces[EdgeKey(u, w)]?.count == 1 {
                    guard holeNext[w] == nil else {
                        throw MeshOpError.nonManifoldRegion("vertex \(w.rawValue) touches multiple boundary loops")
                    }
                    holeNext[w] = u
                }
            }
        }

        // Walk the loop starting at the seed edge's hole-side direction.
        var start = seed.a
        if holeNext[seed.a] != seed.b { start = seed.b }
        guard holeNext[start] == (start == seed.a ? seed.b : seed.a) else {
            throw MeshOpError.nonManifoldRegion("boundary loop is not a simple cycle")
        }
        var loop: [VertexID] = [start]
        var current = holeNext[start]!
        while current != start {
            loop.append(current)
            guard let next = holeNext[current] else {
                throw MeshOpError.nonManifoldRegion("boundary loop is not closed")
            }
            guard loop.count <= mesh.vertexCount else {
                throw MeshOpError.nonManifoldRegion("boundary walk did not terminate")
            }
            current = next
        }
        let n = loop.count
        guard n >= 3 else { throw MeshOpError.preconditionFailed("boundary loop has fewer than 3 vertices") }

        var out = mesh
        var newFaces = Set<FaceID>()
        // Fan triangulation from loop[0].
        for i in 1..<(n - 1) {
            newFaces.insert(out.addFace([loop[0], loop[i], loop[i + 1]]))
        }

        let predicted = TopologyDelta(vertices: 0, edges: n - 3, faces: n - 2)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return MeshOpResult(mesh: out, resultSelection: .faces(newFaces), delta: predicted)
    }
}
