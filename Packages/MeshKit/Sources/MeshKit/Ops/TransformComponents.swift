import Foundation

/// Rigid/affine transform of the vertices touched by a selection:
/// scale → rotate (XYZ Euler, degrees) → translate, about a pivot.
/// Topology delta is zero by construction; the shared post-op invariant check
/// still rejects transforms that flatten faces to zero area.
public enum TransformComponents: MeshOp {
    public static let name = "Transform"

    public struct Params: Sendable {
        public enum Pivot: Sendable, Equatable {
            /// Centroid of the selected vertices (default — "move what I grabbed").
            case selectionCentroid
            case origin
            case point(SIMD3<Double>)
        }

        public var translation: SIMD3<Double>
        public var rotationDegrees: SIMD3<Double>
        public var scale: SIMD3<Double>
        public var pivot: Pivot

        public init(translation: SIMD3<Double> = .zero,
                    rotationDegrees: SIMD3<Double> = .zero,
                    scale: SIMD3<Double> = SIMD3(1, 1, 1),
                    pivot: Pivot = .selectionCentroid) {
            self.translation = translation
            self.rotationDegrees = rotationDegrees
            self.scale = scale
            self.pivot = pivot
        }

        var isIdentity: Bool {
            translation == .zero && rotationDegrees == .zero && scale == SIMD3(1, 1, 1)
        }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        let vertices = try affectedVertices(of: selection, in: mesh)
        guard !vertices.isEmpty else { throw MeshOpError.emptySelection }
        guard abs(params.scale.x) > MeshInvariants.epsilon,
              abs(params.scale.y) > MeshInvariants.epsilon,
              abs(params.scale.z) > MeshInvariants.epsilon else {
            throw MeshOpError.preconditionFailed("scale components must be non-zero")
        }
        guard !params.isIdentity else {
            throw MeshOpError.preconditionFailed("transform is the identity — nothing to do")
        }

        let pivot: SIMD3<Double>
        switch params.pivot {
        case .origin: pivot = .zero
        case .point(let p): pivot = p
        case .selectionCentroid:
            var c = SIMD3<Double>()
            for v in vertices { c += mesh.positions[v]! }
            pivot = c / Double(vertices.count)
        }

        let rotate = rotationMatrixXYZ(degrees: params.rotationDegrees)
        var out = mesh
        for v in vertices.sorted() {
            let local = (mesh.positions[v]! - pivot) * params.scale
            out.setPosition(rotate * local + pivot + params.translation, for: v)
        }

        let predicted = TopologyDelta(vertices: 0, edges: 0, faces: 0)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return MeshOpResult(mesh: out, resultSelection: selection, delta: predicted)
    }

    /// The vertex set a selection touches; throws on missing components so
    /// agents get a referential diagnostic instead of a silent no-op.
    static func affectedVertices(of selection: ComponentSelection,
                                 in mesh: HalfEdgeMesh) throws -> Set<VertexID> {
        switch selection {
        case .vertices(let vs):
            for v in vs where mesh.positions[v] == nil {
                throw MeshOpError.unknownComponent("vertex \(v.rawValue)")
            }
            return vs
        case .edges(let es):
            var out = Set<VertexID>()
            let known = mesh.edgeFaceMap
            for e in es {
                guard known[e] != nil else {
                    throw MeshOpError.unknownComponent("edge (\(e.a.rawValue),\(e.b.rawValue))")
                }
                out.insert(e.a); out.insert(e.b)
            }
            return out
        case .faces(let fs):
            var out = Set<VertexID>()
            for f in fs {
                guard let loop = mesh.faceLoops[f] else {
                    throw MeshOpError.unknownComponent("face \(f.rawValue)")
                }
                out.formUnion(loop)
            }
            return out
        }
    }

    /// Column-major rotation applying X, then Y, then Z.
    static func rotationMatrixXYZ(degrees: SIMD3<Double>) -> Matrix3 {
        let r = degrees * .pi / 180
        let (cx, sx) = (cos(r.x), sin(r.x))
        let (cy, sy) = (cos(r.y), sin(r.y))
        let (cz, sz) = (cos(r.z), sin(r.z))
        let rx = Matrix3(rows: (SIMD3(1, 0, 0), SIMD3(0, cx, -sx), SIMD3(0, sx, cx)))
        let ry = Matrix3(rows: (SIMD3(cy, 0, sy), SIMD3(0, 1, 0), SIMD3(-sy, 0, cy)))
        let rz = Matrix3(rows: (SIMD3(cz, -sz, 0), SIMD3(sz, cz, 0), SIMD3(0, 0, 1)))
        return rz * (ry * rx)
    }
}

/// Minimal 3×3 matrix (row-stored) — keeps MeshKit dependency-free (no simd
/// module import policy is by design; see Package.swift comment).
public struct Matrix3: Sendable, Equatable {
    public var rows: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

    public init(rows: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)) { self.rows = rows }

    public static func * (m: Matrix3, v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(simd_dot(m.rows.0, v), simd_dot(m.rows.1, v), simd_dot(m.rows.2, v))
    }

    public static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        let bc0 = SIMD3(b.rows.0.x, b.rows.1.x, b.rows.2.x)
        let bc1 = SIMD3(b.rows.0.y, b.rows.1.y, b.rows.2.y)
        let bc2 = SIMD3(b.rows.0.z, b.rows.1.z, b.rows.2.z)
        func row(_ r: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(simd_dot(r, bc0), simd_dot(r, bc1), simd_dot(r, bc2))
        }
        return Matrix3(rows: (row(a.rows.0), row(a.rows.1), row(a.rows.2)))
    }

    public static func == (l: Matrix3, r: Matrix3) -> Bool {
        l.rows.0 == r.rows.0 && l.rows.1 == r.rows.1 && l.rows.2 == r.rows.2
    }
}
