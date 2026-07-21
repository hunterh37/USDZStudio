import Foundation
import simd

/// Deterministic "bone-glow" skin binding: each vertex is weighted by inverse-squared distance to
/// each bone segment, keeping the strongest `maxInfluences` and normalizing. A pure, machine-
/// checkable stand-in for a heat-diffusion solve (the optional Python accelerator would replace the
/// solver body behind this same result contract).
public enum WeightSolve {
    /// Solve skin weights binding `mesh` to `skeleton`.
    /// - Parameters:
    ///   - maxInfluences: export-profile influence cap (weights clamped + renormalized to it).
    ///   - falloff: distance exponent; higher = tighter binding.
    public static func solve(mesh: RigMesh, skeleton: Skeleton,
                             maxInfluences: Int = 4, falloff: Double = 2.0) -> SkinBinding {
        let world = skeleton.restWorldMatrices()
        // Bone segments: joint origin → parent origin (roots become a zero-length point at origin).
        let bones: [(a: Vec3, b: Vec3)] = skeleton.joints.indices.map { i in
            let a = Math.origin(of: world[i])
            let b = skeleton.joints[i].parent.map { Math.origin(of: world[$0]) } ?? a
            return (a, b)
        }

        var perVertex: [[Influence]] = []
        perVertex.reserveCapacity(mesh.points.count)
        for p in mesh.points {
            var raw: [Influence] = []
            for (j, seg) in bones.enumerated() {
                let d = distanceToSegment(p, seg.a, seg.b)
                let wgt = 1.0 / pow(d * d + 1e-6, falloff / 2.0)
                raw.append(Influence(joint: j, weight: wgt))
            }
            perVertex.append(raw)
        }
        // Clamp to the influence cap then normalize so every vertex sums to 1.
        return SkinBinding(perVertex: perVertex).conformed(maxInfluences: maxInfluences)
    }

    /// Shortest distance from point `p` to segment `a`–`b`.
    static func distanceToSegment(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
        let ab = b - a
        let denom = simd_dot(ab, ab)
        guard denom > 1e-12 else { return simd_distance(p, a) }
        let t = simd_clamp(simd_dot(p - a, ab) / denom, 0.0, 1.0)
        return simd_distance(p, a + ab * t)
    }
}
