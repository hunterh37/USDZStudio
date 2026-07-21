import Foundation

/// Area-weighted smooth vertex normals for a `FlatMesh`.
///
/// A `UsdGeomMesh` with no authored `normals` falls back to faceted shading in
/// RealityKit / QuickLook, which looks wrong on smooth surfaces and degrades any
/// appearance-based similarity metric (sculpt-accuracy F5). Authoring correct
/// per-vertex normals at build time removes that defect at the source rather
/// than leaving every mesh to a downstream quick-fix.
///
/// The math is deliberately identical in spirit to the editor's quick-fix path:
/// each face contributes its Newell normal — whose magnitude is twice the
/// projected face area — to every vertex it touches, so larger faces dominate
/// the blend the way they visually should. The result is then unit-length.
public enum VertexNormals {

    /// Smooth (area-weighted) per-vertex normals, parallel to `mesh.points`.
    ///
    /// Returns an empty array for topology this cannot honestly interpret —
    /// a `faceVertexCounts` / `faceVertexIndices` mismatch, a face with fewer
    /// than three corners, or an out-of-range index — so callers can treat
    /// "no normals" as the truthful answer rather than authoring garbage.
    ///
    /// A vertex touched by no face, or by faces whose contributions exactly
    /// cancel, gets a zero normal: USD reads that as unshaded, which is more
    /// honest than fabricating a direction.
    public static func smooth(for mesh: FlatMesh) -> [SIMD3<Double>] {
        let points = mesh.points
        guard !points.isEmpty else { return [] }
        let counts = mesh.faceVertexCounts
        let indices = mesh.faceVertexIndices
        guard counts.reduce(0, +) == indices.count,
              !counts.contains(where: { $0 < 3 }),
              !indices.contains(where: { $0 < 0 || $0 >= points.count })
        else { return [] }

        var accumulated = [SIMD3<Double>](repeating: .zero, count: points.count)
        var cursor = 0
        for count in counts {
            let corners = indices[cursor ..< (cursor + count)]
            cursor += count

            // Newell's method: robust for non-planar and concave polygons, and
            // its magnitude is twice the projected face area — exactly the
            // weight we want for an area-weighted blend.
            var normal = SIMD3<Double>.zero
            for (offset, current) in corners.enumerated() {
                let next = corners[corners.startIndex + (offset + 1) % count]
                let a = points[current]
                let b = points[next]
                normal.x += (a.y - b.y) * (a.z + b.z)
                normal.y += (a.z - b.z) * (a.x + b.x)
                normal.z += (a.x - b.x) * (a.y + b.y)
            }
            for corner in corners { accumulated[corner] += normal }
        }

        return accumulated.map { n in
            let length = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            return length > 0 ? n / length : .zero
        }
    }

    /// Smooth normals flattened to the `[x, y, z, …]` layout USD authors as a
    /// `normal3f[]` attribute, parallel to the flat `points` array. Empty when
    /// `smooth(for:)` declines the topology.
    public static func smoothFlat(for mesh: FlatMesh) -> [Double] {
        var flat: [Double] = []
        let normals = smooth(for: mesh)
        flat.reserveCapacity(normals.count * 3)
        for n in normals { flat += [n.x, n.y, n.z] }
        return flat
    }
}
