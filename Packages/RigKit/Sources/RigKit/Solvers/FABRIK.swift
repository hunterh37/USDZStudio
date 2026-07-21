import Foundation
import simd

/// Forward-And-Backward Reaching Inverse Kinematics.
///
/// Solves in position space (bone-length-preserving forward/backward passes) then realizes the
/// solved point chain as joint rotations, root→tip, re-evaluating FK after each so the result is a
/// valid hierarchical pose. Deterministic; reports non-convergence for out-of-reach targets.
public enum FABRIK: RigSolver {
    public static func solve(_ skeleton: Skeleton, pose startPose: Pose, params chain: IKChain) -> SolveResult {
        let count = chain.joints.count
        guard count >= 2 else {
            let residual = chain.joints.isEmpty
                ? Double.infinity
                : simd_distance(startPose.worldPosition(chain.joints[0], in: skeleton), chain.target)
            return SolveResult(pose: startPose, converged: false, iterations: 0, residual: residual)
        }

        let worlds0 = startPose.worldMatrices(skeleton)
        var points = chain.joints.map { Math.origin(of: worlds0[$0]) }
        let lengths = (0..<count - 1).map { simd_distance(points[$0], points[$0 + 1]) }
        let root = points[0]
        let reach = lengths.reduce(0, +)

        var iterations = 0
        let distanceToTarget = simd_distance(root, chain.target)

        if distanceToTarget > reach {
            // Unreachable: stretch straight toward the target (best effort, will not converge).
            let dir = simd_normalize(chain.target - root)
            var acc = root
            for k in 0..<count {
                points[k] = acc
                if k < count - 1 { acc += dir * lengths[k] }
            }
        } else {
            while iterations < chain.maxIterations {
                iterations += 1
                // Backward pass: place effector on the target, walk to the root.
                points[count - 1] = chain.target
                for k in stride(from: count - 2, through: 0, by: -1) {
                    let dir = normalizedOr(points[k] - points[k + 1], fallback: Vec3(1, 0, 0))
                    points[k] = points[k + 1] + dir * lengths[k]
                }
                // Forward pass: pin the root, walk back to the effector.
                points[0] = root
                for k in 1..<count {
                    let dir = normalizedOr(points[k] - points[k - 1], fallback: Vec3(1, 0, 0))
                    points[k] = points[k - 1] + dir * lengths[k - 1]
                }
                if simd_distance(points[count - 1], chain.target) <= chain.tolerance { break }
            }
        }

        // Realize the point chain as joint rotations, root→tip.
        var pose = startPose
        for k in 0..<count - 1 {
            let j = chain.joints[k]
            let worlds = pose.worldMatrices(skeleton)
            let cur = Math.origin(of: worlds[j])
            let childCur = Math.origin(of: worlds[chain.joints[k + 1]])
            let delta = Math.rotationBetween(childCur - cur, points[k + 1] - cur)
            pose = SolverSupport.applyingWorldRotation(delta, at: j, pose: pose, skeleton: skeleton)
        }

        let residual = simd_distance(pose.worldPosition(chain.joints[count - 1], in: skeleton), chain.target)
        return SolveResult(pose: pose, converged: residual <= chain.tolerance,
                           iterations: iterations, residual: residual)
    }

    private static func normalizedOr(_ v: Vec3, fallback: Vec3) -> Vec3 {
        let l = simd_length(v)
        return l > Math.epsilon ? v / l : fallback
    }
}
