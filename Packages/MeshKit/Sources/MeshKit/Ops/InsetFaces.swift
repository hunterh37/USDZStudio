import Foundation

/// Per-face inset (v1): each selected n-gon is replaced by an inner n-gon
/// shrunk toward its centroid plus n side quads.
/// Delta per face: V += n, E += 2n, F += n.
public enum InsetFaces: MeshOp {
    public static let name = "Inset"

    public struct Params: Sendable {
        /// 0 < fraction < 1 — how far each corner moves toward the centroid.
        public var fraction: Double
        public init(fraction: Double) { self.fraction = fraction }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard case .faces(let faces) = selection, !faces.isEmpty else {
            throw MeshOpError.emptySelection
        }
        guard params.fraction > 0, params.fraction < 1 else {
            throw MeshOpError.preconditionFailed("inset fraction must be in (0, 1)")
        }

        var out = mesh
        var predictedV = 0, predictedE = 0, predictedF = 0
        var innerFaces = Set<FaceID>()
        // Batch the original-face removals: deleting each face individually is
        // O(faceCount) per call, so a k-face inset would be O(k · faceCount).
        // Iteration reads the *original* `mesh`, so deferring the removal is safe.
        var facesToRemove = Set<FaceID>()

        for f in faces.sorted() {
            guard let loop = mesh.faceLoops[f] else {
                throw MeshOpError.unknownComponent("face \(f.rawValue)")
            }
            let n = loop.count
            let centroid = mesh.faceCentroid(f)
            // Invariant 6: subset (material) membership carries to the
            // geometry that replaces the inset face.
            let parentSubsets = mesh.subsets.filter { $0.value.contains(f) }.keys

            var inner: [VertexID] = []
            for v in loop {
                let p = mesh.positions[v]!
                inner.append(out.addVertex(p + (centroid - p) * params.fraction))
            }
            // Side quads: traverse the original edge in the original direction
            // (the removed face owned that direction; neighbors run opposite).
            var replacements: [FaceID] = []
            for i in 0..<n {
                let j = (i + 1) % n
                replacements.append(out.addFace([loop[i], loop[j], inner[j], inner[i]]))
            }
            let innerFace = out.addFace(inner)
            innerFaces.insert(innerFace)
            replacements.append(innerFace)
            facesToRemove.insert(f)
            for name in parentSubsets {
                for r in replacements { out.addFaceToSubset(r, subset: name) }
            }

            predictedV += n
            predictedE += 2 * n
            predictedF += n
        }
        out.removeFaces(facesToRemove)

        let predicted = TopologyDelta(vertices: predictedV, edges: predictedE, faces: predictedF)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return MeshOpResult(mesh: out, resultSelection: .faces(innerFaces), delta: predicted)
    }
}
