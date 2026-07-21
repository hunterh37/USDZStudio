import Foundation
import simd

/// Cyclic Coordinate Descent — a general iterative IK solver for chains of any length.
///
/// Each iteration sweeps from the joint just above the effector back to the chain root, rotating
/// every joint so the effector points at the target. Deterministic: no randomness, fixed sweep
/// order. Reports `converged == false` (never a silent bad pose) if the target is out of reach or
/// the iteration cap is hit.
public enum CCD: RigSolver {
    public static func solve(_ skeleton: Skeleton, pose startPose: Pose, params chain: IKChain) -> SolveResult {
        guard chain.joints.count >= 2 else {
            let residual = chain.joints.isEmpty
                ? Double.infinity
                : simd_distance(startPose.worldPosition(chain.joints[0], in: skeleton), chain.target)
            return SolveResult(pose: startPose, converged: false, iterations: 0, residual: residual)
        }
        var pose = startPose
        let effector = chain.joints[chain.joints.count - 1]
        var residual = simd_distance(pose.worldPosition(effector, in: skeleton), chain.target)
        var iterations = 0

        while iterations < chain.maxIterations && residual > chain.tolerance {
            iterations += 1
            // Sweep parents (exclude the effector itself: rotating it can't move its own origin).
            for k in stride(from: chain.joints.count - 2, through: 0, by: -1) {
                let j = chain.joints[k]
                let worlds = pose.worldMatrices(skeleton)
                let pivot = Math.origin(of: worlds[j])
                let effPos = Math.origin(of: worlds[effector])
                let delta = Math.rotationBetween(effPos - pivot, chain.target - pivot)
                pose = SolverSupport.applyingWorldRotation(delta, at: j, pose: pose, skeleton: skeleton)
            }
            residual = simd_distance(pose.worldPosition(effector, in: skeleton), chain.target)
        }
        return SolveResult(pose: pose, converged: residual <= chain.tolerance,
                           iterations: iterations, residual: residual)
    }
}
