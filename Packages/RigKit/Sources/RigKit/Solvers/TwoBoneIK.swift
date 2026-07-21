import Foundation
import simd

/// Closed-form analytic two-bone (limb) IK for a 3-joint chain `[root, mid, effector]`.
///
/// Uses the law of cosines to place the mid joint exactly, choosing the bend plane from the pole
/// vector (or the limb's current bend when no pole is supplied). No iteration — `iterations == 0`.
/// An out-of-reach target straightens the limb and reports `converged == false` with the residual.
public enum TwoBoneIK: RigSolver {
    public static func solve(_ skeleton: Skeleton, pose startPose: Pose, params chain: IKChain) -> SolveResult {
        precondition(chain.joints.count == 3, "TwoBoneIK requires exactly [root, mid, effector]")
        let rootJ = chain.joints[0], midJ = chain.joints[1], effJ = chain.joints[2]

        let worlds0 = startPose.worldMatrices(skeleton)
        let a = Math.origin(of: worlds0[rootJ])
        let midCur = Math.origin(of: worlds0[midJ])
        let effCur = Math.origin(of: worlds0[effJ])

        let upperLen = simd_distance(a, midCur)
        let lowerLen = simd_distance(midCur, effCur)

        // Degenerate limb (zero-length bone) — nothing to solve.
        guard upperLen > Math.epsilon, lowerLen > Math.epsilon else {
            let residual = simd_distance(effCur, chain.target)
            return SolveResult(pose: startPose, converged: residual <= chain.tolerance,
                               iterations: 0, residual: residual)
        }

        let toTarget = chain.target - a
        let dist = simd_clamp(simd_length(toTarget), abs(upperLen - lowerLen) + 1e-9, upperLen + lowerLen)
        let dir = simd_length(toTarget) > Math.epsilon ? toTarget / simd_length(toTarget) : Vec3(1, 0, 0)

        // Interior angle at the root between (target direction) and (upper bone).
        let cosA = simd_clamp((upperLen * upperLen + dist * dist - lowerLen * lowerLen)
                              / (2 * upperLen * dist), -1.0, 1.0)
        let angleA = acos(cosA)

        // Bend direction: perpendicular component of the pole (or current knee) relative to `dir`.
        let poleWorld = chain.poleVector ?? midCur
        var perp = (poleWorld - a) - dir * simd_dot(poleWorld - a, dir)
        if simd_length(perp) < 1e-9 {
            // Fully straight and no usable pole: pick a stable perpendicular to `dir`.
            perp = simd_cross(dir, Vec3(0, 1, 0))
            if simd_length(perp) < 1e-9 { perp = simd_cross(dir, Vec3(1, 0, 0)) }
        }
        let bendDir = simd_normalize(perp)

        let midGoal = a + dir * (upperLen * cos(angleA)) + bendDir * (upperLen * sin(angleA))

        // Realize as world rotations: root aims the upper bone at the mid goal, then the mid aims
        // the lower bone at the target.
        var pose = startPose
        let rootDelta = Math.rotationBetween(midCur - a, midGoal - a)
        pose = SolverSupport.applyingWorldRotation(rootDelta, at: rootJ, pose: pose, skeleton: skeleton)

        let worlds1 = pose.worldMatrices(skeleton)
        let newMid = Math.origin(of: worlds1[midJ])
        let newEff = Math.origin(of: worlds1[effJ])
        let midDelta = Math.rotationBetween(newEff - newMid, chain.target - newMid)
        pose = SolverSupport.applyingWorldRotation(midDelta, at: midJ, pose: pose, skeleton: skeleton)

        let residual = simd_distance(pose.worldPosition(effJ, in: skeleton), chain.target)
        return SolveResult(pose: pose, converged: residual <= chain.tolerance,
                           iterations: 0, residual: residual)
    }
}
