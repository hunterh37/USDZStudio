import XCTest
import simd
@testable import RigKit

final class RetargetTests: XCTestCase {
    func testIdentityRetargetReproducesSource() {
        let skel = SkelCorpus.mixamo
        let mapping = HumanoidMap.identify(skel)
        let rest = Pose(rest: skel)

        // A source clip: rotate one arm and translate the hips over time.
        let armIdx = skel.index(ofID: "LeftArm")!
        let hipsIdx = skel.index(ofID: "Hips")!
        var channels = [[Keyframe]](repeating: [], count: skel.jointCount)
        for t in [0.0, 0.5, 1.0] {
            channels[armIdx].append(Keyframe(time: t, transform:
                RigTransform(translation: skel.joints[armIdx].restLocal.translation,
                             rotation: Quat(axis: Vec3(0, 0, 1), degrees: 30 * t))))
            channels[hipsIdx].append(Keyframe(time: t, transform:
                RigTransform(translation: skel.joints[hipsIdx].restLocal.translation + Vec3(t, 0, 0))))
        }
        let source = Clip(name: "src", channels: channels, startTime: 0, endTime: 1)

        let retargeted = Retargeter.retarget(sourceClip: source, source: skel, sourceMapping: mapping,
                                             target: skel, targetMapping: mapping, sampleTimes: [0, 0.5, 1])
        for t in [0.0, 0.5, 1.0] {
            let a = source.sample(at: t, rest: rest).worldPositions(skel)
            let b = retargeted.sample(at: t, rest: rest).worldPositions(skel)
            for (pa, pb) in zip(a, b) {
                XCTAssertLessThan(simd_distance(pa, pb), 1e-6)
            }
        }
        XCTAssertEqual(retargeted.name, "src_retargeted")
    }

    func testHipAtZeroHeightKeepsRatioOne() {
        // Source whose Hips sits at world Y = 0 → ratio guard keeps hipRatio = 1.
        let flat = Skeleton(joints: [
            RigJoint(id: "Hips", path: "Hips", parent: nil, restLocal: .identity),
            RigJoint(id: "Spine", path: "Hips/Spine", parent: 0, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
        ])
        let mapping = HumanoidMap.identify(flat)
        let clip = Clip(name: "c", channels: [[Keyframe(time: 0, transform: .identity)], []],
                        startTime: 0, endTime: 0)
        let out = Retargeter.retarget(sourceClip: clip, source: flat, sourceMapping: mapping,
                                      target: flat, targetMapping: mapping, sampleTimes: [0])
        XCTAssertEqual(out.jointCount, 2)
    }

    func testNoCommonBonesProducesEmptyChannels() {
        let humanoid = SkelCorpus.mixamo
        let generic = SkeletonFit.fitGeneric(RigMesh(points: [Vec3(0, 0, 0), Vec3(0, 2, 0)]), jointCount: 3)
        let out = Retargeter.retarget(
            sourceClip: Clip(name: "x", channels: Array(repeating: [], count: humanoid.jointCount), startTime: 0, endTime: 1),
            source: humanoid, sourceMapping: HumanoidMap.identify(humanoid),
            target: generic, targetMapping: HumanoidMap.identify(generic), sampleTimes: [0, 1])
        XCTAssertTrue(out.channels.allSatisfy { $0.isEmpty })
    }
}
