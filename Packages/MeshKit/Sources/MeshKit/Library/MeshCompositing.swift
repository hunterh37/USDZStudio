import Foundation

/// Affine transforms and merging for `HalfEdgeMesh`, the building blocks the
/// prefab library uses to compose real-world low-poly objects out of the
/// parametric `Primitives`.
///
/// All operations preserve topology (loops, UVs) and produce meshes that keep
/// the Primitives contract: positive-scale transforms and rotations preserve
/// outward winding, and merging closed parts yields a closed, manifold mesh
/// (a disjoint union — Euler characteristic is `2 × parts`, not 2).
public extension HalfEdgeMesh {

    /// Returns a copy with `f` applied to every vertex position. Topology,
    /// UVs, and subsets are untouched.
    func mapPositions(_ f: (SIMD3<Double>) -> SIMD3<Double>) -> HalfEdgeMesh {
        var copy = self
        for v in vertexOrder { copy.setPosition(f(positions[v]!), for: v) }
        return copy
    }

    /// Translated copy.
    func translated(by t: SIMD3<Double>) -> HalfEdgeMesh {
        mapPositions { $0 + t }
    }

    /// Per-axis scaled copy. Components must be positive to keep outward
    /// winding (a negative factor mirrors and flips face normals).
    func scaled(by s: SIMD3<Double>) -> HalfEdgeMesh {
        mapPositions { $0 * s }
    }

    /// Uniformly scaled copy.
    func scaled(by s: Double) -> HalfEdgeMesh {
        scaled(by: SIMD3(s, s, s))
    }

    /// Copy rotated `radians` about the +Y axis (right-handed).
    func rotatedY(_ radians: Double) -> HalfEdgeMesh {
        let c = cos(radians), s = sin(radians)
        return mapPositions { SIMD3($0.x * c + $0.z * s, $0.y, -$0.x * s + $0.z * c) }
    }

    /// Copy rotated `radians` about the +X axis (right-handed).
    func rotatedX(_ radians: Double) -> HalfEdgeMesh {
        let c = cos(radians), s = sin(radians)
        return mapPositions { SIMD3($0.x, $0.y * c - $0.z * s, $0.y * s + $0.z * c) }
    }

    /// Disjoint union of `meshes` into one mesh, remapping vertex ids so parts
    /// stay independent (no welding). Each part keeps its own faces and UVs;
    /// subsets are dropped (v1 prefabs are single-material). Merging closed
    /// parts yields a closed, manifold mesh.
    static func merged(_ meshes: [HalfEdgeMesh]) -> HalfEdgeMesh {
        var out = HalfEdgeMesh()
        for m in meshes {
            var remap: [VertexID: VertexID] = [:]
            remap.reserveCapacity(m.vertexCount)
            for v in m.vertexOrder { remap[v] = out.addVertex(m.positions[v]!) }
            for f in m.faceOrder {
                let loop = m.faceLoops[f]!.map { remap[$0]! }
                _ = out.addFace(loop, uvs: m.faceCornerUVs[f])
            }
        }
        return out
    }
}
