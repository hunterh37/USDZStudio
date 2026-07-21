import XCTest
import simd
@testable import RigKit

final class QuatTests: XCTestCase {
    func testIdentityAndAxisAngle() {
        XCTAssertEqual(Quat.identity, Quat(w: 1, x: 0, y: 0, z: 0))
        // 90° about +Y rotates +X to -Z.
        let q = Quat(axis: Vec3(0, 1, 0), degrees: 90)
        let v = q.act(Vec3(1, 0, 0))
        XCTAssertEqual(v.x, 0, accuracy: 1e-9)
        XCTAssertEqual(v.z, -1, accuracy: 1e-9)
    }

    func testDegenerateAxisIsIdentity() {
        XCTAssertEqual(Quat(axis: .zero, degrees: 45), .identity)
    }

    func testLengthAndNormalize() {
        let q = Quat(w: 0, x: 3, y: 0, z: 4)
        XCTAssertEqual(q.length, 5, accuracy: 1e-12)
        XCTAssertEqual(q.lengthSquared, 25, accuracy: 1e-12)
        XCTAssertEqual(q.normalized.length, 1, accuracy: 1e-12)
        // Zero quaternion normalizes to identity.
        XCTAssertEqual(Quat(w: 0, x: 0, y: 0, z: 0).normalized, .identity)
    }

    func testMultiplyAndConjugate() {
        let a = Quat(axis: Vec3(0, 0, 1), degrees: 30)
        let b = Quat(axis: Vec3(0, 0, 1), degrees: 60)
        let product = a.multiplied(by: b)
        // Composition about the same axis adds angles → 90°.
        let v = product.act(Vec3(1, 0, 0))
        XCTAssertEqual(v.y, 1, accuracy: 1e-9)
        XCTAssertEqual(a.conjugate.x, -a.x)
    }

    func testDotAndSlerpShortestArc() {
        let a = Quat.identity
        let b = Quat(axis: Vec3(0, 1, 0), degrees: 90)
        let mid = a.slerp(to: b, t: 0.5)
        let v = mid.act(Vec3(1, 0, 0))
        // Halfway to 90° is 45°.
        XCTAssertEqual(v.x, cos(45 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(a.dot(a), 1, accuracy: 1e-12)
    }

    func testSlerpNegativeDotFlips() {
        let a = Quat.identity
        // A quaternion equivalent to identity but with negative w forces the shortest-arc flip.
        let b = Quat(w: -1, x: 0, y: 0, z: 0)
        let mid = a.slerp(to: b, t: 0.5)
        XCTAssertEqual(abs(mid.w), 1, accuracy: 1e-9)
    }

    func testSlerpNearlyParallelUsesLinear() {
        let a = Quat.identity
        let b = Quat(axis: Vec3(0, 1, 0), degrees: 0.0000001)
        let mid = a.slerp(to: b, t: 0.5)
        XCTAssertEqual(mid.length, 1, accuracy: 1e-9)
    }

    func testMatrixRoundTripThroughFromMatrix() {
        for deg in stride(from: 10.0, through: 350.0, by: 47.0) {
            for axis in [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 1, 1)] {
                let q = Quat(axis: axis, degrees: deg).normalized
                let back = Quat.fromMatrix(q.matrix)
                // q and -q represent the same rotation; compare via action on a vector.
                let p = Vec3(0.3, -0.7, 0.5)
                XCTAssertLessThan(simd_length(q.act(p) - back.act(p)), 1e-9)
            }
        }
    }

    func testFromMatrixAllBranches() {
        // trace>0 branch: identity.
        _ = Quat.fromMatrix(matrix_identity_double4x4)
        // Each negative-trace branch is hit by 180° rotations about X, Y, Z.
        for axis in [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)] {
            let q = Quat(axis: axis, degrees: 180).normalized
            let back = Quat.fromMatrix(q.matrix)
            let p = Vec3(0.2, 0.9, -0.4)
            XCTAssertLessThan(simd_length(q.act(p) - back.act(p)), 1e-9)
        }
    }

    func testCodable() throws {
        let q = Quat(w: 0.1, x: 0.2, y: 0.3, z: 0.4)
        let data = try JSONEncoder().encode(q)
        XCTAssertEqual(try JSONDecoder().decode(Quat.self, from: data), q)
    }
}

final class MathHelperTests: XCTestCase {
    func testTranslationScaleTRS() {
        let t = Math.translation(Vec3(1, 2, 3))
        XCTAssertEqual(Math.origin(of: t), Vec3(1, 2, 3))
        let s = Math.scale(Vec3(2, 2, 2))
        let p = s * SIMD4<Double>(1, 1, 1, 1)
        XCTAssertEqual(p.x, 2, accuracy: 1e-12)
        let trs = Math.trs(translation: Vec3(0, 1, 0), rotation: .identity, scale: Vec3(1, 1, 1))
        XCTAssertEqual(Math.origin(of: trs), Vec3(0, 1, 0))
    }

    func testRowMajorRoundTrip() {
        let m = Math.trs(translation: Vec3(1, 2, 3),
                         rotation: Quat(axis: Vec3(0, 1, 0), degrees: 33), scale: Vec3(1, 1, 1))
        let flat = Math.rowMajor(m)
        XCTAssertEqual(flat.count, 16)
        let back = Math.fromRowMajor(flat)
        XCTAssertLessThan(Math.maxComponentDifference(m, back), 1e-12)
    }

    func testFromRowMajorWrongLengthIsIdentity() {
        XCTAssertEqual(Math.fromRowMajor([1, 2, 3]), matrix_identity_double4x4)
    }

    func testRotationBetween() {
        // Aligned → identity.
        XCTAssertEqual(Math.rotationBetween(Vec3(1, 0, 0), Vec3(2, 0, 0)), .identity)
        // Degenerate input → identity.
        XCTAssertEqual(Math.rotationBetween(.zero, Vec3(1, 0, 0)), .identity)
        XCTAssertEqual(Math.rotationBetween(Vec3(1, 0, 0), .zero), .identity)
        // Perpendicular.
        let q = Math.rotationBetween(Vec3(1, 0, 0), Vec3(0, 1, 0))
        XCTAssertLessThan(simd_length(q.act(Vec3(1, 0, 0)) - Vec3(0, 1, 0)), 1e-9)
        // Anti-parallel (both fallbacks).
        let anti = Math.rotationBetween(Vec3(1, 0, 0), Vec3(-1, 0, 0))
        XCTAssertLessThan(simd_length(anti.act(Vec3(1, 0, 0)) - Vec3(-1, 0, 0)), 1e-9)
        let antiY = Math.rotationBetween(Vec3(0, 1, 0), Vec3(0, -1, 0))
        XCTAssertLessThan(simd_length(antiY.act(Vec3(0, 1, 0)) - Vec3(0, -1, 0)), 1e-9)
    }

    func testRotationOfScaledMatrix() {
        let q = Quat(axis: Vec3(0, 1, 0), degrees: 40).normalized
        let m = Math.translation(Vec3(5, 0, 0)) * q.matrix * Math.scale(Vec3(3, 3, 3))
        let extracted = Math.rotation(of: m)
        let p = Vec3(1, 0.5, -0.2)
        XCTAssertLessThan(simd_length(extracted.act(p) - q.act(p)), 1e-9)
    }

    func testRotationOfDegenerateColumn() {
        var m = matrix_identity_double4x4
        m.columns.0 = SIMD4<Double>(0, 0, 0, 0) // zero-length basis column exercises the guard
        _ = Math.rotation(of: m)
    }

    func testApplyingWorldRotationRootAndChild() {
        let root = RigJoint(id: "r", path: "r", parent: nil, restLocal: .identity)
        let child = RigJoint(id: "c", path: "r/c", parent: 0,
                             restLocal: RigTransform(translation: Vec3(0, 1, 0)))
        let skel = Skeleton(joints: [root, child])
        let pose = Pose(rest: skel)
        // Rotate the root 90° about Z in world space; the child should swing to +X-ish.
        let rotated = SolverSupport.applyingWorldRotation(
            Quat(axis: Vec3(0, 0, 1), degrees: 90), at: 0, pose: pose, skeleton: skel)
        let childPos = rotated.worldPosition(1, in: skel)
        XCTAssertEqual(childPos.x, -1, accuracy: 1e-9)
        // Applying at the child (has a parent) exercises the parent-rotation branch.
        _ = SolverSupport.applyingWorldRotation(
            Quat(axis: Vec3(1, 0, 0), degrees: 30), at: 1, pose: rotated, skeleton: skel)
    }
}
