import XCTest
import simd
@testable import RigKit

final class MotionQualityTests: XCTestCase {
    /// A 2-joint skeleton (root + tip at +Y) posed by rotating the root about Z.
    let skel = Skeleton(joints: [
        RigJoint(id: "root", path: "root", parent: nil, restLocal: .identity),
        RigJoint(id: "tip", path: "root/tip", parent: 0, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
    ])

    func poses(_ angles: [Double]) -> [Pose] {
        angles.map { Pose(locals: [
            RigTransform(rotation: Quat(axis: Vec3(0, 0, 1), degrees: $0)),
            RigTransform(translation: Vec3(0, 1, 0)),
        ]) }
    }

    func uniformTimes(_ n: Int) -> [Double] { (0..<n).map { Double($0) / Double(n - 1) } }

    func testNilWhenUnmeasurable() {
        XCTAssertNil(MotionQuality.assess(MotionSample(skeleton: skel, poses: poses([0]), times: [0])))
        // Mismatched counts.
        XCTAssertNil(MotionQuality.assess(MotionSample(skeleton: skel, poses: poses([0, 1, 2]), times: [0, 1])))
    }

    func testSmoothClipScoresAboveFloorAndJitteryBelow() {
        let n = 16
        let times = uniformTimes(n)
        // Smooth ease-in/ease-out (sine-bell speed) → high smoothness + naturalness.
        let smoothAngles = (0..<n).map { i -> Double in
            30.0 * (1 - cos(.pi * Double(i) / Double(n - 1))) / 2
        }
        let smooth = MotionQuality.assess(MotionSample(skeleton: skel, poses: poses(smoothAngles), times: times))!
        XCTAssertGreaterThanOrEqual(smooth.measuredMotionQuality, MotionQuality.defaultFloor)

        // Jittery: alternating extremes → high jerk, non-bell speed.
        let jitterAngles = (0..<n).map { i -> Double in i % 2 == 0 ? 0.0 : 45.0 }
        let jittery = MotionQuality.assess(MotionSample(skeleton: skel, poses: poses(jitterAngles), times: times))!
        XCTAssertLessThan(jittery.measuredMotionQuality, MotionQuality.defaultFloor)
        XCTAssertLessThan(jittery.smoothness, smooth.smoothness)
    }

    func testTwoSampleGuardsReturnUnitySubmetrics() {
        // Exactly 2 poses exercises the smoothness/naturalness/seam short-sample guards.
        let r = MotionQuality.assess(MotionSample(skeleton: skel, poses: poses([0, 10]), times: [0, 1]))!
        XCTAssertEqual(r.smoothness, 1)
        XCTAssertEqual(r.naturalness, 1)
        XCTAssertEqual(r.seamContinuity, 1)
    }

    func testFootSlide() {
        // Foot at world y = 0 (root at +1, foot child at -1).
        let footSkel = Skeleton(joints: [
            RigJoint(id: "h", path: "h", parent: nil, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
            RigJoint(id: "f", path: "h/f", parent: 0, restLocal: RigTransform(translation: Vec3(0, -1, 0))),
        ])
        let planted = [Pose(rest: footSkel), Pose(rest: footSkel), Pose(rest: footSkel)]
        let noSlide = MotionQuality.assess(MotionSample(skeleton: footSkel, poses: planted,
                                                        times: [0, 1, 2], footJoints: [1], groundY: 0))!
        XCTAssertEqual(noSlide.footSlide, 1, accuracy: 1e-9)

        // Foot drifts horizontally while planted.
        let sliding = (0..<3).map { i in
            Pose(locals: [RigTransform(translation: Vec3(Double(i) * 0.2, 1, 0)),
                          RigTransform(translation: Vec3(0, -1, 0))])
        }
        let slid = MotionQuality.assess(MotionSample(skeleton: footSkel, poses: sliding,
                                                     times: [0, 1, 2], footJoints: [1], groundY: 0))!
        XCTAssertLessThan(slid.footSlide, 1)
    }

    func testInterpenetration() {
        let s = Fixtures.chain4()
        let rest = [Pose(rest: s)]
        let none = MotionQuality.assess(MotionSample(skeleton: s, poses: rest + rest, times: [0, 1], boneRadius: 0))!
        XCTAssertEqual(none.interpenetration, 1, accuracy: 1e-9)
        let fat = MotionQuality.assess(MotionSample(skeleton: s, poses: rest + rest, times: [0, 1], boneRadius: 5))!
        XCTAssertLessThan(fat.interpenetration, 1)
    }

    func testLimitCompliance() {
        let posed = poses([90, 90])
        let inLimit = [JointLimit(joint: 0, axis: Vec3(0, 0, 1), minDegrees: 0, maxDegrees: 180)]
        let compliant = MotionQuality.assess(MotionSample(skeleton: skel, poses: posed, times: [0, 1], limits: inLimit))!
        XCTAssertEqual(compliant.limitCompliance, 1, accuracy: 1e-6)

        let tight = [JointLimit(joint: 0, axis: Vec3(0, 0, 1), minDegrees: 0, maxDegrees: 10)]
        let violating = MotionQuality.assess(MotionSample(skeleton: skel, poses: posed, times: [0, 1], limits: tight))!
        XCTAssertLessThan(violating.limitCompliance, 1)

        // IK residual health factor.
        let residual = MotionQuality.assess(MotionSample(skeleton: skel, poses: posed, times: [0, 1],
                                                         limits: inLimit, ikResidual: 1.0))!
        XCTAssertLessThan(residual.limitCompliance, 0.01)
    }

    func testSeamContinuity() {
        // Velocity jump at the middle sample.
        let jumpy = [
            Pose(locals: [RigTransform(translation: Vec3(0, 0, 0)), RigTransform(translation: Vec3(0, 1, 0))]),
            Pose(locals: [RigTransform(translation: Vec3(0.1, 0, 0)), RigTransform(translation: Vec3(0, 1, 0))]),
            Pose(locals: [RigTransform(translation: Vec3(5, 0, 0)), RigTransform(translation: Vec3(0, 1, 0))]),
        ]
        let r = MotionQuality.assess(MotionSample(skeleton: skel, poses: jumpy, times: [0, 1, 2], seamTimes: [1]))!
        XCTAssertLessThan(r.seamContinuity, 1)
    }

    func testReportCodable() throws {
        let r = MotionQuality.assess(MotionSample(skeleton: skel, poses: poses([0, 10]), times: [0, 1]))!
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(MotionQualityReport.self, from: data), r)
    }
}

final class MotionQualityHelperTests: XCTestCase {
    func testSwingAngle() {
        // 90° about Z.
        let q = Quat(axis: Vec3(0, 0, 1), degrees: 90)
        XCTAssertEqual(MotionQuality.swingAngle(q, about: Vec3(0, 0, 1)), 90, accuracy: 1e-6)
        // Degenerate axis falls back to the total rotation angle.
        XCTAssertEqual(MotionQuality.swingAngle(q, about: .zero), 90, accuracy: 1e-6)
    }

    func testCorrelation() {
        XCTAssertEqual(MotionQuality.correlation([1], [1]), 1)                 // n <= 1 guard
        XCTAssertEqual(MotionQuality.correlation([2, 2, 2], [1, 2, 3]), 0)     // zero variance → 0
        XCTAssertEqual(MotionQuality.correlation([1, 2, 3], [1, 2, 3]), 1, accuracy: 1e-9)
    }

    func testSegmentSegmentDistanceBranches() {
        // Both degenerate (points).
        XCTAssertEqual(MotionQuality.segmentSegmentDistance(Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(3, 0, 0), Vec3(3, 0, 0)), 3, accuracy: 1e-9)
        // First degenerate.
        XCTAssertEqual(MotionQuality.segmentSegmentDistance(Vec3(0, 1, 0), Vec3(0, 1, 0), Vec3(0, 0, 0), Vec3(2, 0, 0)), 1, accuracy: 1e-9)
        // Second degenerate.
        XCTAssertEqual(MotionQuality.segmentSegmentDistance(Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(1, 3, 0), Vec3(1, 3, 0)), 3, accuracy: 1e-9)
        // Parallel segments (denom ~ 0) and general skew.
        _ = MotionQuality.segmentSegmentDistance(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(1, 1, 0))
        // t clamped beyond ends.
        _ = MotionQuality.segmentSegmentDistance(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(5, 5, 0), Vec3(6, 6, 0))
        _ = MotionQuality.segmentSegmentDistance(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(-5, 5, 0), Vec3(-6, 6, 0))
    }
}
