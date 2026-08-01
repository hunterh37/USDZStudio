import Foundation

/// Face-varying UV generation.
///
/// Generated geometry used to carry no `primvars:st` at all, which made every
/// texture map in a `MaterialSpec` unrenderable no matter how correct the shader
/// network was — the maps had nothing to map onto (#170). Worse, the drop was
/// all-or-nothing: `MeshIO.flat` only exports the UV channel when *every* face
/// has UVs, so a single face minted by `extrude`/`inset`/`bevel`/`subdivide`
/// discarded the entire set.
///
/// UVs live per face corner (USD `faceVarying` interpolation) rather than per
/// vertex. That is what lets a seam exist: the two sides of a cylinder's seam
/// share a vertex but need `u = 0` on one side and `u = 1` on the other.
///
/// The projections here are deliberately simple and deterministic — a box,
/// cylindrical, or spherical unwrap in the mesh's own local space, normalized by
/// its bounds. That is not a substitute for a real atlas-packing unwrapper, but
/// it is a correct, seam-repaired, uniformly-scaled layout, which is what noise,
/// marble, facade, and other procedural maps actually need.
public enum MeshUV {

    /// How to parametrize a mesh's surface.
    public enum Projection: Sendable, Equatable {
        /// Per-face planar projection along the face normal's dominant axis.
        /// The natural fit for boxes, planes, and arbitrary faceted geometry.
        case box
        /// Angle around +Y → `u`, height → `v`. For cylinders and cones.
        case cylindrical
        /// Longitude → `u`, latitude → `v`. For spheres.
        case spherical
    }

    /// Author UVs for **every** face, replacing any that already exist.
    public static func unwrap(_ mesh: inout HalfEdgeMesh, using projection: Projection) {
        apply(&mesh, projection: projection, onlyMissing: false)
    }

    /// Author UVs only for faces that have none, leaving existing UVs untouched.
    ///
    /// This is the safety net that keeps a topology op from destroying the whole
    /// channel: ops that mint faces (extrude, inset, bevel, subdivide) leave the
    /// new faces UV-less, and without this the exporter drops every face's UVs
    /// rather than just the new ones.
    public static func fillMissing(_ mesh: inout HalfEdgeMesh,
                                   using projection: Projection = .box) {
        apply(&mesh, projection: projection, onlyMissing: true)
    }

    /// `true` when every face carries UVs parallel to its loop — the condition
    /// `MeshIO.flat` requires before it will export the channel.
    public static func isFullyUnwrapped(_ mesh: HalfEdgeMesh) -> Bool {
        guard !mesh.faceOrder.isEmpty else { return false }
        return mesh.faceOrder.allSatisfy { face in
            guard let uvs = mesh.faceCornerUVs[face],
                  let loop = mesh.faceLoops[face] else { return false }
            return uvs.count == loop.count
        }
    }

    // MARK: - Implementation

    static func apply(_ mesh: inout HalfEdgeMesh, projection: Projection, onlyMissing: Bool) {
        guard !mesh.faceOrder.isEmpty else { return }
        let bounds = self.bounds(of: mesh)
        for face in mesh.faceOrder {
            guard let loop = mesh.faceLoops[face] else { continue }
            if onlyMissing, mesh.faceCornerUVs[face]?.count == loop.count { continue }
            let corners = loop.compactMap { mesh.positions[$0] }
            guard corners.count == loop.count else { continue }
            mesh.setFaceUVs(uvs(for: corners, projection: projection, bounds: bounds), for: face)
        }
    }

    /// UVs for one face's corner positions.
    static func uvs(for corners: [SIMD3<Double>], projection: Projection,
                    bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> [SIMD2<Double>] {
        switch projection {
        case .box:
            return boxUVs(corners, bounds: bounds)
        case .cylindrical:
            return repairSeam(corners.map { cylindricalUV($0, bounds: bounds) })
        case .spherical:
            return repairSeam(corners.map { sphericalUV($0) })
        }
    }

    /// Planar projection onto the two axes the face's normal is *least* aligned
    /// with, normalized by the mesh bounds so scale is uniform across faces.
    static func boxUVs(_ corners: [SIMD3<Double>],
                       bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> [SIMD2<Double>] {
        let n = normal(of: corners)
        let size = extent(bounds)
        let ax = SIMD3(Swift.abs(n.x), Swift.abs(n.y), Swift.abs(n.z))
        // Dominant axis of the normal is dropped; the remaining two become
        // (u, v). Axis pairs are chosen so u × v points along the normal, which
        // keeps texture handedness consistent from face to face.
        let (uAxis, vAxis): (Int, Int)
        if ax.x >= ax.y && ax.x >= ax.z {
            (uAxis, vAxis) = (2, 1)          // +X face: z → u, y → v
        } else if ax.y >= ax.z {
            (uAxis, vAxis) = (0, 2)          // +Y face: x → u, z → v
        } else {
            (uAxis, vAxis) = (0, 1)          // +Z face: x → u, y → v
        }
        return corners.map { p in
            SIMD2(normalize(p[uAxis], min: bounds.min[uAxis], size: size[uAxis]),
                  normalize(p[vAxis], min: bounds.min[vAxis], size: size[vAxis]))
        }
    }

    /// Angle about +Y → u (0...1), normalized height → v.
    static func cylindricalUV(_ p: SIMD3<Double>,
                              bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> SIMD2<Double> {
        let size = extent(bounds)
        let u = (atan2(p.z, p.x) / (2 * .pi)) + 0.5
        return SIMD2(u, normalize(p.y, min: bounds.min.y, size: size.y))
    }

    /// Longitude → u, latitude → v, from the direction of `p` about the origin.
    /// Primitives are origin-centered, so no re-centering is needed.
    static func sphericalUV(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let length = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        guard length > 1e-12 else { return SIMD2(0.5, 0.5) }
        let u = (atan2(p.z, p.x) / (2 * .pi)) + 0.5
        let v = 1 - acos(min(1, max(-1, p.y / length))) / .pi
        return SIMD2(u, v)
    }

    /// Repair the wrap seam of an angular projection.
    ///
    /// A face straddling the θ = π seam gets corner `u`s like `[0.98, 0.02]`,
    /// which stretches the texture backwards across the entire map. Detect the
    /// straddle by the corner spread and lift the low side by 1 so the face
    /// reads as `[0.98, 1.02]` — continuous, and exactly what face-varying UVs
    /// exist to express.
    static func repairSeam(_ uvs: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard uvs.count >= 2 else { return uvs }
        let us = uvs.map(\.x)
        guard let lo = us.min(), let hi = us.max(), hi - lo > 0.5 else { return uvs }
        return uvs.map { $0.x < 0.5 ? SIMD2($0.x + 1, $0.y) : $0 }
    }

    // MARK: - Geometry helpers

    static func bounds(of mesh: HalfEdgeMesh) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: 0)
        var hi = SIMD3<Double>(repeating: 0)
        var seen = false
        for v in mesh.vertexOrder {
            guard let p = mesh.positions[v] else { continue }
            if !seen { lo = p; hi = p; seen = true; continue }
            lo = SIMD3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
            hi = SIMD3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
        }
        return (lo, hi)
    }

    /// Bounds size with degenerate axes floored to 1, so a flat plane (zero
    /// thickness in Y) still divides safely.
    static func extent(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> SIMD3<Double> {
        let raw = bounds.max - bounds.min
        return SIMD3(raw.x > 1e-12 ? raw.x : 1,
                     raw.y > 1e-12 ? raw.y : 1,
                     raw.z > 1e-12 ? raw.z : 1)
    }

    static func normalize(_ value: Double, min: Double, size: Double) -> Double {
        (value - min) / size
    }

    /// Newell's method — correct for non-planar and concave polygons, unlike a
    /// single cross product of the first three corners.
    static func normal(of corners: [SIMD3<Double>]) -> SIMD3<Double> {
        var n = SIMD3<Double>(repeating: 0)
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        }
        return n
    }
}
