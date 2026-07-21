import Foundation
import simd

/// Maps motion from one rigged humanoid onto another via the canonical bone correspondence.
///
/// Rotation retarget with rest-pose reconciliation: each mapped joint receives the source joint's
/// *change from its rest pose*, re-based onto the target's rest pose. Hip translation is scaled by
/// the rest hip-height ratio (scale normalization), which is the primary foot-slide reducer.
public enum Retargeter {
    /// Retarget `sourceClip` (authored on `source`) onto `target`, sampling at `sampleTimes`.
    /// Only canonical bones matched on both rigs are transferred.
    public static func retarget(sourceClip: Clip, source: Skeleton, sourceMapping: HumanoidMapping,
                                target: Skeleton, targetMapping: HumanoidMapping,
                                sampleTimes: [Double]) -> Clip {
        let sourceRest = Pose(rest: source)
        let sourceRestWorld = source.restWorldMatrices()
        let targetRestWorld = target.restWorldMatrices()

        // Correspondence: canonical bone → (sourceJoint, targetJoint).
        var pairs: [(canonical: String, s: Int, t: Int)] = []
        for bone in HumanoidMap.canonicalBones {
            if let s = sourceMapping.jointIndex(for: bone.name),
               let t = targetMapping.jointIndex(for: bone.name) {
                pairs.append((bone.name, s, t))
            }
        }

        // Hip-height ratio for translation normalization.
        var hipRatio = 1.0
        if let s = sourceMapping.jointIndex(for: "Hips"), let t = targetMapping.jointIndex(for: "Hips") {
            let sY = Math.origin(of: sourceRestWorld[s]).y
            let tY = Math.origin(of: targetRestWorld[t]).y
            if abs(sY) > 1e-9 { hipRatio = tY / sY }
        }

        var channels = [[Keyframe]](repeating: [], count: target.jointCount)
        for time in sampleTimes.sorted() {
            let srcPose = sourceClip.sample(at: time, rest: sourceRest)
            for pair in pairs {
                let sAnim = srcPose.locals[pair.s]
                let sRest = source.joints[pair.s].restLocal
                let tRest = target.joints[pair.t].restLocal
                let delta = sRest.rotation.conjugate.multiplied(by: sAnim.rotation).normalized
                let tRot = tRest.rotation.multiplied(by: delta).normalized

                var tTrans = tRest.translation
                if pair.canonical == "Hips" {
                    tTrans = tRest.translation + (sAnim.translation - sRest.translation) * hipRatio
                }
                channels[pair.t].append(Keyframe(
                    time: time,
                    transform: RigTransform(translation: tTrans, rotation: tRot, scale: tRest.scale)))
            }
        }
        let start = sampleTimes.min() ?? 0
        let end = sampleTimes.max() ?? 0
        return Clip(name: sourceClip.name + "_retargeted", channels: channels,
                    startTime: start, endTime: end)
    }
}
