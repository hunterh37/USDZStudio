import XCTest
import simd
@testable import RigKit

final class SkeletonFitTests: XCTestCase {
    /// A 2m-tall, 0.6m-wide box of vertices.
    func bodyMesh(scale: Double = 1) -> RigMesh {
        RigMesh(points: [
            Vec3(-0.3 * scale, 0, -0.15 * scale), Vec3(0.3 * scale, 0, 0.15 * scale),
            Vec3(-0.3 * scale, 2 * scale, -0.15 * scale), Vec3(0.3 * scale, 2 * scale, 0.15 * scale),
        ])
    }

    func testHumanoidLandmarksAndSymmetry() {
        let skel = SkeletonFit.fitHumanoid(bodyMesh())
        let world = skel.restWorldMatrices()
        func y(_ id: String) -> Double { Math.origin(of: world[skel.index(ofID: id)!]).y }
        // Hips ~53% up a 2m body ≈ 1.06m.
        XCTAssertEqual(y("Hips"), 1.06, accuracy: 1e-6)
        XCTAssertGreaterThan(y("Head"), y("Neck"))
        XCTAssertGreaterThan(y("Neck"), y("Chest"))
        // Left/right symmetry about the mid-plane (x = 0).
        func x(_ id: String) -> Double { Math.origin(of: world[skel.index(ofID: id)!]).x }
        XCTAssertEqual(x("LeftUpperLeg"), -x("RightUpperLeg"), accuracy: 1e-9)
        XCTAssertEqual(x("LeftHand"), -x("RightHand"), accuracy: 1e-9)
    }

    func testDeterministicAndScaleNormalized() {
        XCTAssertEqual(SkeletonFit.fitHumanoid(bodyMesh()), SkeletonFit.fitHumanoid(bodyMesh()))
        let small = SkeletonFit.fitHumanoid(bodyMesh(scale: 1))
        let big = SkeletonFit.fitHumanoid(bodyMesh(scale: 2))
        let smallY = Math.origin(of: small.restWorldMatrices()[small.index(ofID: "Hips")!]).y
        let bigY = Math.origin(of: big.restWorldMatrices()[big.index(ofID: "Hips")!]).y
        XCTAssertEqual(bigY, smallY * 2, accuracy: 1e-6)
    }

    func testHumanoidFitIsIdentifiable() {
        let mapping = HumanoidMap.identify(SkeletonFit.fitHumanoid(bodyMesh()))
        XCTAssertNotNil(mapping.jointIndex(for: "LeftHand"))
        XCTAssertNotNil(mapping.jointIndex(for: "Hips"))
    }

    func testGenericAndDispatchAndEmptyMesh() {
        let generic = SkeletonFit.fit(bodyMesh(), kind: .generic)
        XCTAssertEqual(generic.jointCount, 5)
        // jointCount < 2 is clamped up to 2.
        XCTAssertEqual(SkeletonFit.fitGeneric(bodyMesh(), jointCount: 1).jointCount, 2)
        // Dispatch to humanoid.
        XCTAssertEqual(SkeletonFit.fit(bodyMesh(), kind: .humanoid).jointCount,
                       SkeletonFit.fitHumanoid(bodyMesh()).jointCount)
        // Empty mesh → zero bounds, still builds a valid skeleton.
        XCTAssertEqual(RigMesh(points: []).bounds.min, .zero)
        XCTAssertTrue(RigInvariants.isValid(SkeletonFit.fitGeneric(RigMesh(points: []), jointCount: 3)))
    }

    func testKindCodable() throws {
        let data = try JSONEncoder().encode(AutoRigKind.humanoid)
        XCTAssertEqual(try JSONDecoder().decode(AutoRigKind.self, from: data), .humanoid)
    }
}

final class WeightSolveTests: XCTestCase {
    func testSolveProducesNormalizedCappedWeights() {
        let skel = Fixtures.chain4()
        // Vertices scattered near the chain.
        let mesh = RigMesh(points: [
            Vec3(0, 0.5, 0), Vec3(0.1, 1.5, 0), Vec3(-0.1, 2.5, 0), Vec3(0, 2.9, 0),
        ])
        let skin = WeightSolve.solve(mesh: mesh, skeleton: skel, maxInfluences: 2)
        XCTAssertLessThan(RigInvariants.weightSumResidual(skin), 1e-9)
        XCTAssertTrue(RigInvariants.respectsInfluenceCap(skin, cap: 2))
        XCTAssertEqual(skin.vertexCount, 4)
    }

    func testDistanceToSegmentZeroLength() {
        // Degenerate segment (a == b) → point distance.
        XCTAssertEqual(WeightSolve.distanceToSegment(Vec3(3, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0)), 3, accuracy: 1e-9)
        // Projection clamped to the segment ends.
        XCTAssertEqual(WeightSolve.distanceToSegment(Vec3(-1, 0, 0), Vec3(0, 0, 0), Vec3(2, 0, 0)), 1, accuracy: 1e-9)
        XCTAssertEqual(WeightSolve.distanceToSegment(Vec3(1, 1, 0), Vec3(0, 0, 0), Vec3(2, 0, 0)), 1, accuracy: 1e-9)
    }
}
