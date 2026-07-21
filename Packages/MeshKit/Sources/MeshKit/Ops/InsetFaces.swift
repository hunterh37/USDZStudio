import Foundation
import simd

/// Per-face inset: each selected n-gon is replaced by an inner n-gon
/// shrunk toward its centroid (`fraction`) and optionally offset along the
/// face normal (`depth`), plus n side quads.
/// Delta per face: V += n, E += 2n, F += n.
///
/// `depth` is what makes the inset visibly *deform* the surface: with
/// `depth == 0` the inner ring is coplanar with the original face (a pure
/// in-plane inset — invisible on a flat face except for the new edges).
/// A negative `depth` pushes the inner face inward along the normal (the
/// "punched-in panel" look); positive raises it outward.
public enum InsetFaces: MeshOp {
    public static let name = "Inset"

    public struct Params: Sendable {
        /// 0 < fraction < 1 — how far each corner moves toward the centroid.
        public var fraction: Double
        /// Signed offset of the inner ring along the (unit) face normal.
        /// 0 = coplanar (classic inset); negative = inward; positive = outward.
        public var depth: Double
        public init(fraction: Double, depth: Double = 0) {
            self.fraction = fraction
            self.depth = depth
        }
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

            // Offset applied to every inner vertex along the face normal.
            // Guard against a degenerate (zero-area) face: no normal ⇒ no
            // depth, which cleanly falls back to a coplanar inset.
            var offset = SIMD3<Double>()
            if params.depth != 0 {
                let areaNormal = mesh.faceNormalArea(f)
                let len = simd_length(areaNormal)
                if len > 1e-12 { offset = areaNormal / len * params.depth }
            }

            var inner: [VertexID] = []
            for v in loop {
                let p = mesh.positions[v]!
                inner.append(out.addVertex(p + (centroid - p) * params.fraction + offset))
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
