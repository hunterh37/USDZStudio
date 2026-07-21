import XCTest
import simd
@testable import RigKit

final class ClipTests: XCTestCase {
    let skel = Fixtures.limb()

    func makeClip() -> Clip {
        Clip(name: "walk", channels: [
            // joint 0: translate from origin to (2,0,0) over [0,1] (keys added out of order to test sort)
            [Keyframe(time: 1, transform: RigTransform(translation: Vec3(2, 0, 0))),
             Keyframe(time: 0, transform: RigTransform(translation: Vec3(0, 0, 0)))],
            [],   // joint 1: empty → rest fallback
            [Keyframe(time: 0, transform: RigTransform(translation: Vec3(0, 1, 0)))],   // single key
        ], startTime: 0, endTime: 1)
    }

    func testSampleBounds() {
        let clip = makeClip()
        let rest = Pose(rest: skel)
        // Before first key → first value.
        XCTAssertEqual(clip.sample(at: -1, rest: rest).local(0).translation, Vec3(0, 0, 0))
        // After last key → last value.
        XCTAssertEqual(clip.sample(at: 5, rest: rest).local(0).translation, Vec3(2, 0, 0))
        // Between → linear interpolation.
        XCTAssertEqual(clip.sample(at: 0.5, rest: rest).local(0).translation, Vec3(1, 0, 0))
        // Empty channel → rest local.
        XCTAssertEqual(clip.sample(at: 0.5, rest: rest).local(1).translation, Vec3(0, 1, 0))
        // Single-key channel: before/after both clamp to it.
        XCTAssertEqual(clip.sample(at: 0.5, rest: rest).local(2).translation, Vec3(0, 1, 0))
        XCTAssertEqual(clip.jointCount, 3)
        XCTAssertEqual(clip.duration, 1)
    }

    func testSampleCoincidentKeysZeroSpan() {
        // Two keys at the same time → span 0 branch (u = 0).
        let clip = Clip(name: "z", channels: [[
            Keyframe(time: 0, transform: RigTransform(translation: Vec3(0, 0, 0))),
            Keyframe(time: 0, transform: RigTransform(translation: Vec3(9, 9, 9))),
            Keyframe(time: 2, transform: RigTransform(translation: Vec3(4, 0, 0))),
        ]], startTime: 0, endTime: 2)
        // Between the coincident pair and the far key still interpolates.
        _ = clip.sample(at: 1, rest: Pose(locals: [.identity]))
    }

    func testSettingKeyframe() {
        var clip = makeClip()
        clip = clip.settingKeyframe(Keyframe(time: 0, transform: RigTransform(translation: Vec3(5, 0, 0))), joint: 0)
        XCTAssertEqual(clip.sample(at: 0, rest: Pose(rest: skel)).local(0).translation, Vec3(5, 0, 0))
        clip = clip.settingKeyframe(Keyframe(time: 0.5, transform: RigTransform(translation: Vec3(7, 0, 0))), joint: 0)
        XCTAssertEqual(clip.sample(at: 0.5, rest: Pose(rest: skel)).local(0).translation, Vec3(7, 0, 0))
    }

    func testTrimmed() {
        let trimmed = makeClip().trimmed(start: 0.75, end: 0.25)   // reversed → swapped
        XCTAssertEqual(trimmed.startTime, 0.25)
        XCTAssertEqual(trimmed.endTime, 0.75)
        XCTAssertTrue(trimmed.channels[0].isEmpty)   // both keys (t=0, t=1) fall outside
    }

    func testRetimed() {
        let doubled = makeClip().retimed(scale: 2, offset: 1)
        XCTAssertEqual(doubled.startTime, 1)
        XCTAssertEqual(doubled.endTime, 3)   // duration 1 * 2 + offset 1
        // Non-positive scale falls back to 1.
        let same = makeClip().retimed(scale: 0, offset: 0)
        XCTAssertEqual(same.endTime, 1)
    }

    func testCodable() throws {
        let data = try JSONEncoder().encode(makeClip())
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: data).name, "walk")
    }
}

final class PoseBlendTests: XCTestCase {
    func testBlend() {
        let a = Pose(locals: [RigTransform(translation: Vec3(0, 0, 0), scale: Vec3(1, 1, 1))])
        let b = Pose(locals: [RigTransform(translation: Vec3(2, 0, 0),
                                           rotation: Quat(axis: Vec3(0, 0, 1), degrees: 90),
                                           scale: Vec3(3, 3, 3))])
        XCTAssertEqual(PoseBlend.blend(a, b, t: 0).local(0).translation, Vec3(0, 0, 0))
        XCTAssertEqual(PoseBlend.blend(a, b, t: 1).local(0).translation, Vec3(2, 0, 0))
        let mid = PoseBlend.blend(a, b, t: 0.5)
        XCTAssertEqual(mid.local(0).translation, Vec3(1, 0, 0))
        XCTAssertEqual(mid.local(0).scale, Vec3(2, 2, 2))
        // t clamps above 1.
        XCTAssertEqual(PoseBlend.blend(a, b, t: 5).local(0).translation, Vec3(2, 0, 0))
    }

    func testBlendMismatchedCounts() {
        let a = Pose(locals: [.identity, .identity])
        let b = Pose(locals: [.identity])
        XCTAssertEqual(PoseBlend.blend(a, b, t: 0.5).jointCount, 1)   // min of the two
    }

    func testAdditive() {
        let base = Pose(locals: [RigTransform(translation: Vec3(1, 0, 0))])
        let reference = Pose(locals: [RigTransform(translation: Vec3(0, 0, 0))])
        let layer = Pose(locals: [RigTransform(translation: Vec3(0, 2, 0),
                                               rotation: Quat(axis: Vec3(0, 0, 1), degrees: 40))])
        let full = PoseBlend.additive(base: base, layer: layer, reference: reference, weight: 1)
        XCTAssertEqual(full.local(0).translation, Vec3(1, 2, 0))   // base + (layer - reference)
        let none = PoseBlend.additive(base: base, layer: layer, reference: reference, weight: 0)
        XCTAssertEqual(none.local(0).translation, Vec3(1, 0, 0))   // weight 0 → base
    }
}

final class BlendNodeTests: XCTestCase {
    let skel = Fixtures.limb()

    func testEvaluateAllNodeKinds() {
        let rest = Pose(rest: skel)
        let clipA = Clip(name: "a", channels: [
            [Keyframe(time: 0, transform: RigTransform(translation: Vec3(0, 0, 0)))], [], [],
        ], startTime: 0, endTime: 1)
        let clipB = Clip(name: "b", channels: [
            [Keyframe(time: 0, transform: RigTransform(translation: Vec3(4, 0, 0)))], [], [],
        ], startTime: 0, endTime: 1)

        let leaf = BlendNode.clip(clipA)
        XCTAssertEqual(leaf.evaluate(at: 0, rest: rest).local(0).translation, Vec3(0, 0, 0))

        let blended = BlendNode.blend(.clip(clipA), .clip(clipB), weight: 0.5)
        XCTAssertEqual(blended.evaluate(at: 0, rest: rest).local(0).translation, Vec3(2, 0, 0))

        let additive = BlendNode.additive(base: .clip(clipA), layer: .clip(clipB),
                                          reference: rest, weight: 1)
        _ = additive.evaluate(at: 0, rest: rest)
    }
}
