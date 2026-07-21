import Foundation

/// Delete faces / edges+adjacent-faces / vertices+adjacent-faces.
/// Vertices left without any face are pruned (documented isolation rule).
public enum DeleteComponents: MeshOp {
    public static let name = "Delete"
    public struct Params: Sendable { public init() {} }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params = .init()) throws -> MeshOpResult {
        guard !selection.isEmpty else { throw MeshOpError.emptySelection }

        var facesToDelete = Set<FaceID>()
        switch selection {
        case .faces(let faces):
            for f in faces {
                guard mesh.faceLoops[f] != nil else {
                    throw MeshOpError.unknownComponent("face \(f.rawValue)")
                }
            }
            facesToDelete = faces
        case .edges(let edges):
            let edgeFaces = mesh.edgeFaceMap
            for e in edges {
                guard let adjacent = edgeFaces[e] else {
                    throw MeshOpError.unknownComponent("edge (\(e.a.rawValue),\(e.b.rawValue))")
                }
                facesToDelete.formUnion(adjacent)
            }
        case .vertices(let verts):
            let vertexFaces = mesh.vertexFaceMap
            for v in verts {
                guard mesh.positions[v] != nil else {
                    throw MeshOpError.unknownComponent("vertex \(v.rawValue)")
                }
                facesToDelete.formUnion(vertexFaces[v] ?? [])
            }
        }

        var out = mesh
        out.removeFaces(facesToDelete)
        out.pruneIsolatedVertices()
        // Extra rule for explicit vertex deletion: the vertices themselves go too.
        if case .vertices(let verts) = selection {
            out.removeVertices(verts.filter { out.positions[$0] != nil })
        }

        let delta = TopologyDelta(vertices: out.vertexCount - mesh.vertexCount,
                                  edges: out.edgeCount - mesh.edgeCount,
                                  faces: out.faceCount - mesh.faceCount)
        try OpSupport.verify(before: mesh, after: out, predicted: delta)
        return MeshOpResult(mesh: out, resultSelection: .faces([]), delta: delta)
    }
}
