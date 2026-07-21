import XCTest
import simd
@testable import RigKit

/// A shared 3-joint vertical chain: root at origin, mid at y=1, tip at y=2.
enum Fixtures {
    static func limb() -> Skeleton {
        Skeleton(joints: [
            RigJoint(id: "root", path: "root", parent: nil, restLocal: .identity),
            RigJoint(id: "mid", path: "root/mid", parent: 0,
                     restLocal: RigTransform(translation: Vec3(0, 1, 0))),
            RigJoint(id: "tip", path: "root/mid/tip", parent: 1,
                     restLocal: RigTransform(translation: Vec3(0, 1, 0))),
        ])
    }
}

final class SkeletonTests: XCTestCase {
    func testRigJointNameAndTransformMatrix() {
        let j = RigJoint(id: "a", path: "root/mid/tip", parent: 1, restLocal: .identity)
        XCTAssertEqual(j.name, "tip")
        // A joint whose path has no slash returns the whole path.
        XCTAssertEqual(RigJoint(id: "b", path: "solo", parent: nil, restLocal: .identity).name, "solo")
        XCTAssertEqual(Math.origin(of: RigTransform(translation: Vec3(1, 2, 3)).matrix), Vec3(1, 2, 3))
        XCTAssertEqual(RigTransform.identity, RigTransform())
    }

    func testIndexingAndTopology() {
        let s = Fixtures.limb()
        XCTAssertEqual(s.jointCount, 3)
        XCTAssertEqual(s.index(ofID: "mid"), 1)
        XCTAssertNil(s.index(ofID: "nope"))
        XCTAssertEqual(s.index(ofPath: "root/mid/tip"), 2)
        XCTAssertNil(s.index(ofPath: "nope"))
        XCTAssertEqual(s.children(of: 0), [1])
        XCTAssertEqual(s.children(of: 2), [])
        XCTAssertEqual(s.ancestors(of: 2), [0, 1, 2])
        XCTAssertEqual(s.ancestors(of: 0), [0])
    }

    func testRestWorldMatricesFK() {
        let world = Fixtures.limb().restWorldMatrices()
        XCTAssertEqual(Math.origin(of: world[0]), Vec3(0, 0, 0))
        XCTAssertEqual(Math.origin(of: world[1]), Vec3(0, 1, 0))
        XCTAssertEqual(Math.origin(of: world[2]), Vec3(0, 2, 0))
    }

    func testSetRestLocalAndUSDMapping() {
        var s = Fixtures.limb()
        s.setRestLocal(RigTransform(translation: Vec3(0, 2, 0)), at: 1)
        XCTAssertEqual(Math.origin(of: s.restWorldMatrices()[2]), Vec3(0, 3, 0))
        XCTAssertEqual(s.jointPaths, ["root", "root/mid", "root/mid/tip"])
        XCTAssertEqual(s.restTransformsFlat.count, 48)
    }

    func testCodable() throws {
        let s = Fixtures.limb()
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(Skeleton.self, from: data), s)
    }

    func testDecomposeTransform() {
        let original = RigTransform(translation: Vec3(1, 2, 3),
                                    rotation: Quat(axis: Vec3(0, 1, 0), degrees: 40),
                                    scale: Vec3(2, 3, 4))
        let back = RigTransform(decomposing: original.matrix)
        XCTAssertLessThan(simd_distance(back.translation, original.translation), 1e-9)
        XCTAssertLessThan(simd_distance(back.scale, original.scale), 1e-9)
        let p = Vec3(0.5, -0.3, 0.2)
        XCTAssertLessThan(simd_length(back.rotation.act(p) - original.rotation.act(p)), 1e-9)
    }

    func testInitFromUsdSkelArrays() {
        let limb = Fixtures.limb()
        let rebuilt = Skeleton(jointPaths: limb.jointPaths, restTransformsFlat: limb.restTransformsFlat)
        let s = try! XCTUnwrap(rebuilt)
        XCTAssertEqual(s.jointCount, 3)
        XCTAssertEqual(s.joints[2].parent, 1)                          // parent derived from path
        XCTAssertEqual(s.joints[0].parent, nil)                        // root
        XCTAssertLessThan(simd_distance(s.joints[1].restLocal.translation, Vec3(0, 1, 0)), 1e-9)
        // Length mismatch → nil.
        XCTAssertNil(Skeleton(jointPaths: ["a"], restTransformsFlat: [1, 2, 3]))
        // Unknown parent path → treated as root.
        let orphan = Skeleton(jointPaths: ["a/b"], restTransformsFlat: Array(repeating: 0, count: 16).enumerated().map { $0.offset % 5 == 0 ? 1 : 0 })
        XCTAssertEqual(orphan?.joints[0].parent, nil)
    }
}

final class PoseTests: XCTestCase {
    func testRestPoseAndAccessors() {
        let s = Fixtures.limb()
        let pose = Pose(rest: s)
        XCTAssertEqual(pose.jointCount, 3)
        XCTAssertEqual(pose.local(1).translation, Vec3(0, 1, 0))
        XCTAssertEqual(pose.worldPositions(s)[2], Vec3(0, 2, 0))
        XCTAssertEqual(pose.worldPosition(1, in: s), Vec3(0, 1, 0))
    }

    func testSettingIsPureCopy() {
        let s = Fixtures.limb()
        let pose = Pose(rest: s)
        let edited = pose.setting(RigTransform(translation: Vec3(1, 0, 0)), at: 0)
        XCTAssertEqual(pose.local(0).translation, .zero)      // original unchanged
        XCTAssertEqual(edited.local(0).translation, Vec3(1, 0, 0))
    }

    func testAnimationChannelFlattening() {
        let pose = Pose(locals: [
            RigTransform(translation: Vec3(1, 2, 3),
                         rotation: Quat(w: 1, x: 0, y: 0, z: 0), scale: Vec3(2, 2, 2)),
        ])
        XCTAssertEqual(pose.translationsFlat, [1, 2, 3])
        XCTAssertEqual(pose.rotationsFlat, [1, 0, 0, 0])   // (w,x,y,z) order
        XCTAssertEqual(pose.scalesFlat, [2, 2, 2])
    }

    func testCodable() throws {
        let pose = Pose(rest: Fixtures.limb())
        let data = try JSONEncoder().encode(pose)
        XCTAssertEqual(try JSONDecoder().decode(Pose.self, from: data), pose)
    }
}
