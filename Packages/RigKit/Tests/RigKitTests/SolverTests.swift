import XCTest
import simd
@testable import RigKit

extension Fixtures {
    /// A 4-joint vertical chain (reach 3) for the general iterative solvers.
    static func chain4() -> Skeleton {
        Skeleton(joints: [
            RigJoint(id: "j0", path: "j0", parent: nil, restLocal: .identity),
            RigJoint(id: "j1", path: "j0/j1", parent: 0, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
            RigJoint(id: "j2", path: "j0/j1/j2", parent: 1, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
            RigJoint(id: "j3", path: "j0/j1/j2/j3", parent: 2, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
        ])
    }
}

final class TwoBoneIKTests: XCTestCase {
    let skel = Fixtures.limb()

    func testReachableConverges() {
        let pose = Pose(rest: skel)
        let chain = IKChain(joints: [0, 1, 2], target: Vec3(1, 1, 0))
        let r = TwoBoneIK.solve(skel, pose: pose, params: chain)
        XCTAssertTrue(r.converged)
        XCTAssertEqual(r.iterations, 0)                      // analytic
        XCTAssertLessThan(r.residual, 1e-4)
        XCTAssertLessThan(simd_distance(r.pose.worldPosition(2, in: skel), Vec3(1, 1, 0)), 1e-4)
    }

    func testWithPoleVector() {
        let pose = Pose(rest: skel)
        let chain = IKChain(joints: [0, 1, 2], target: Vec3(1, 1, 0), poleVector: Vec3(2, 1, 0))
        let r = TwoBoneIK.solve(skel, pose: pose, params: chain)
        XCTAssertTrue(r.converged)
    }

    func testStraightTargetHitsPerpendicularFallback() {
        // Target collinear with the (vertical) limb and pole == mid → both fallbacks.
        let r = TwoBoneIK.solve(skel, pose: Pose(rest: skel),
                                params: IKChain(joints: [0, 1, 2], target: Vec3(0, 1.5, 0)))
        XCTAssertTrue(r.converged)
    }

    func testOutOfReachStraightensAndReportsResidual() {
        let r = TwoBoneIK.solve(skel, pose: Pose(rest: skel),
                                params: IKChain(joints: [0, 1, 2], target: Vec3(5, 0, 0)))
        XCTAssertFalse(r.converged)
        XCTAssertGreaterThan(r.residual, 1)
    }

    func testDegenerateZeroLengthBone() {
        // mid coincident with root → zero-length upper bone.
        let degenerate = Skeleton(joints: [
            RigJoint(id: "r", path: "r", parent: nil, restLocal: .identity),
            RigJoint(id: "m", path: "r/m", parent: 0, restLocal: .identity),
            RigJoint(id: "t", path: "r/m/t", parent: 1, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
        ])
        let r = TwoBoneIK.solve(degenerate, pose: Pose(rest: degenerate),
                                params: IKChain(joints: [0, 1, 2], target: Vec3(0, 1, 0)))
        XCTAssertEqual(r.iterations, 0)
        XCTAssertTrue(r.converged)   // tip already at target
    }
}

final class CCDTests: XCTestCase {
    func testConverges() {
        let s = Fixtures.chain4()
        let r = CCD.solve(s, pose: Pose(rest: s), params: IKChain(joints: [0, 1, 2, 3], target: Vec3(1.5, 1.5, 0)))
        XCTAssertTrue(r.converged)
        XCTAssertGreaterThan(r.iterations, 0)
        XCTAssertLessThan(r.residual, 1e-4)
    }

    func testOutOfReachDoesNotConverge() {
        let s = Fixtures.chain4()
        let r = CCD.solve(s, pose: Pose(rest: s), params: IKChain(joints: [0, 1, 2, 3], target: Vec3(20, 0, 0)))
        XCTAssertFalse(r.converged)
        XCTAssertEqual(r.iterations, 32)   // hits the cap
    }

    func testShortChains() {
        let s = Fixtures.limb()
        let empty = CCD.solve(s, pose: Pose(rest: s), params: IKChain(joints: [], target: .zero))
        XCTAssertFalse(empty.converged)
        XCTAssertEqual(empty.residual, .infinity)
        let single = CCD.solve(s, pose: Pose(rest: s), params: IKChain(joints: [1], target: Vec3(0, 1, 0)))
        XCTAssertFalse(single.converged)
        XCTAssertEqual(single.residual, 0, accuracy: 1e-9)
    }
}

final class FABRIKTests: XCTestCase {
    func testConverges() {
        let s = Fixtures.chain4()
        let r = FABRIK.solve(s, pose: Pose(rest: s), params: IKChain(joints: [0, 1, 2, 3], target: Vec3(1.5, 1.5, 0)))
        XCTAssertTrue(r.converged)
        XCTAssertLessThan(r.residual, 1e-3)
    }

    func testUnreachableStretchesStraight() {
        let s = Fixtures.chain4()
        let r = FABRIK.solve(s, pose: Pose(rest: s), params: IKChain(joints: [0, 1, 2, 3], target: Vec3(10, 0, 0)))
        XCTAssertFalse(r.converged)
        XCTAssertEqual(r.iterations, 0)   // straight-line branch does no iterations
    }

    func testShortChains() {
        let s = Fixtures.limb()
        XCTAssertFalse(FABRIK.solve(s, pose: Pose(rest: s), params: IKChain(joints: [], target: .zero)).converged)
        let single = FABRIK.solve(s, pose: Pose(rest: s), params: IKChain(joints: [2], target: Vec3(0, 2, 0)))
        XCTAssertEqual(single.residual, 0, accuracy: 1e-9)
    }
}

final class IKDispatchTests: XCTestCase {
    func testKindParsing() {
        XCTAssertEqual(IKSolverKind(parsing: "twobone"), .twoBone)
        XCTAssertEqual(IKSolverKind(parsing: "two_bone"), .twoBone)
        XCTAssertEqual(IKSolverKind(parsing: "analytic"), .twoBone)
        XCTAssertEqual(IKSolverKind(parsing: "FABRIK"), .fabrik)
        XCTAssertEqual(IKSolverKind(parsing: "ccd"), .ccd)
        XCTAssertEqual(IKSolverKind(parsing: nil), .ccd)
        XCTAssertEqual(IKSolverKind(parsing: "weird"), .ccd)
    }

    func testDispatch() {
        let limb = Fixtures.limb()
        let two = IKSolvers.solve(limb, pose: Pose(rest: limb),
                                  chain: IKChain(joints: [0, 1, 2], target: Vec3(1, 1, 0)), kind: .twoBone)
        XCTAssertEqual(two.iterations, 0)

        // twoBone requested for a 4-joint chain falls back to CCD.
        let s4 = Fixtures.chain4()
        let fallback = IKSolvers.solve(s4, pose: Pose(rest: s4),
                                       chain: IKChain(joints: [0, 1, 2, 3], target: Vec3(1.5, 1.5, 0)), kind: .twoBone)
        XCTAssertTrue(fallback.converged)

        let ccd = IKSolvers.solve(s4, pose: Pose(rest: s4),
                                  chain: IKChain(joints: [0, 1, 2, 3], target: Vec3(1.5, 1.5, 0)), kind: .ccd)
        XCTAssertTrue(ccd.converged)
        let fab = IKSolvers.solve(s4, pose: Pose(rest: s4),
                                  chain: IKChain(joints: [0, 1, 2, 3], target: Vec3(1.5, 1.5, 0)), kind: .fabrik)
        XCTAssertTrue(fab.converged)
    }

    func testSolverKindCodable() throws {
        let data = try JSONEncoder().encode(IKSolverKind.fabrik)
        XCTAssertEqual(try JSONDecoder().decode(IKSolverKind.self, from: data), .fabrik)
    }
}

final class ConstraintTests: XCTestCase {
    func twoJoint() -> Skeleton {
        Skeleton(joints: [
            RigJoint(id: "a", path: "a", parent: nil, restLocal: .identity),
            RigJoint(id: "b", path: "a/b", parent: 0, restLocal: RigTransform(translation: Vec3(0, 1, 0))),
        ])
    }

    func testPointFromWorldAndJoint() {
        let s = twoJoint()
        let pose = Pose(rest: s)
        let world = Constraints.apply(
            [Constraint(constrained: 1, source: .worldPosition(Vec3(2, 2, 2)), kind: .point)], to: pose, skeleton: s)
        XCTAssertLessThan(simd_distance(world.worldPosition(1, in: s), Vec3(2, 2, 2)), 1e-9)

        let jointSrc = Constraints.apply(
            [Constraint(constrained: 1, source: .joint(0), kind: .point)], to: pose, skeleton: s)
        XCTAssertLessThan(simd_distance(jointSrc.worldPosition(1, in: s), Vec3(0, 0, 0)), 1e-9)
    }

    func testOrientParentScaleAim() {
        let s = twoJoint()
        let pose = Pose(rest: s)
        let rot = Quat(axis: Vec3(0, 0, 1), degrees: 90)
        let orient = Constraints.apply([Constraint(
            constrained: 1,
            source: .worldTransform(position: .zero, rotation: rot, scale: Vec3(1, 1, 1)),
            kind: .orient)], to: pose, skeleton: s)
        XCTAssertLessThan(simd_length(Math.rotation(of: orient.worldMatrices(s)[1]).act(Vec3(1, 0, 0)) - rot.act(Vec3(1, 0, 0))), 1e-9)

        let parent = Constraints.apply([Constraint(
            constrained: 1,
            source: .worldTransform(position: Vec3(3, 0, 0), rotation: rot, scale: Vec3(1, 1, 1)),
            kind: .parent)], to: pose, skeleton: s)
        XCTAssertLessThan(simd_distance(parent.worldPosition(1, in: s), Vec3(3, 0, 0)), 1e-9)

        let scaled = Constraints.apply([Constraint(
            constrained: 1,
            source: .worldTransform(position: .zero, rotation: .identity, scale: Vec3(3, 3, 3)),
            kind: .scale)], to: pose, skeleton: s)
        XCTAssertEqual(scaled.local(1).scale, Vec3(3, 3, 3))

        // Aim joint 1's +X axis toward a point on +X.
        let aim = Constraints.apply([Constraint(
            constrained: 1, source: .worldPosition(Vec3(5, 1, 0)), kind: .aim)], to: pose, skeleton: s)
        let dir = Math.rotation(of: aim.worldMatrices(s)[1]).act(Vec3(1, 0, 0))
        XCTAssertGreaterThan(dir.x, 0.9)
    }

    func testWeightZeroIsNoOpAndClamp() {
        let s = twoJoint()
        let pose = Pose(rest: s)
        let zero = Constraints.apply(
            [Constraint(constrained: 1, source: .worldPosition(Vec3(9, 9, 9)), kind: .point, weight: 0)],
            to: pose, skeleton: s)
        XCTAssertEqual(zero, pose)
        // Weight > 1 clamps to 1 (full).
        let full = Constraints.apply(
            [Constraint(constrained: 1, source: .worldPosition(Vec3(2, 2, 2)), kind: .point, weight: 5)],
            to: pose, skeleton: s)
        XCTAssertLessThan(simd_distance(full.worldPosition(1, in: s), Vec3(2, 2, 2)), 1e-9)
    }

    func testConstraintKindCodable() throws {
        let data = try JSONEncoder().encode(ConstraintKind.aim)
        XCTAssertEqual(try JSONDecoder().decode(ConstraintKind.self, from: data), .aim)
    }
}
