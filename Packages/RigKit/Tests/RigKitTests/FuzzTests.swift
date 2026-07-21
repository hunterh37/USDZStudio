import XCTest
import simd
@testable import RigKit

/// Randomized invariant corpus (mirrors MechanismKit's in-suite fuzz test).
final class FuzzTests: XCTestCase {
    func testSolverDeterminismAndConvergence() {
        var rng = SystemRandomNumberGenerator()
        func r(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rng) }

        for _ in 0..<300 {
            // Random 3-link limb with positive bone lengths.
            let l1 = r(0.5, 2), l2 = r(0.5, 2)
            let skel = Skeleton(joints: [
                RigJoint(id: "r", path: "r", parent: nil, restLocal: .identity),
                RigJoint(id: "m", path: "r/m", parent: 0, restLocal: RigTransform(translation: Vec3(0, l1, 0))),
                RigJoint(id: "t", path: "r/m/t", parent: 1, restLocal: RigTransform(translation: Vec3(0, l2, 0))),
            ])
            let pose = Pose(rest: skel)
            // A target guaranteed within reach: a random direction scaled below (l1+l2).
            let dir = simd_normalize(Vec3(r(-1, 1), r(-1, 1), r(-1, 1)) + Vec3(0.001, 0.001, 0.001))
            // Strictly between the fold radius |l1-l2| and full extension l1+l2 → truly reachable.
            let reach = r(abs(l1 - l2) + 0.1, (l1 + l2) - 0.1)
            let target = dir * reach
            let chain = IKChain(joints: [0, 1, 2], target: target, tolerance: 1e-3, maxIterations: 64)

            // Determinism: identical inputs → identical outputs, per solver.
            for kind in IKSolverKind.allCases {
                let a = IKSolvers.solve(skel, pose: pose, chain: chain, kind: kind)
                let b = IKSolvers.solve(skel, pose: pose, chain: chain, kind: kind)
                XCTAssertEqual(a, b)
                // A non-converged result must honestly report residual > tolerance.
                if !a.converged { XCTAssertGreaterThan(a.residual, chain.tolerance) }
            }
            // The analytic solver must reach an in-reach target.
            let analytic = TwoBoneIK.solve(skel, pose: pose, params: chain)
            XCTAssertTrue(analytic.converged, "analytic failed to reach in-reach target; residual \(analytic.residual)")
        }
    }

    func testSkinNormalizeFuzz() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let count = Int.random(in: 1...6, using: &rng)
            let influences = (0..<count).map {
                Influence(joint: $0, weight: Double.random(in: 0.01...5, using: &rng))
            }
            let skin = SkinBinding(perVertex: [influences]).conformed(maxInfluences: 4)
            XCTAssertLessThan(RigInvariants.weightSumResidual(skin), 1e-9)
            XCTAssertTrue(RigInvariants.respectsInfluenceCap(skin, cap: 4))
        }
    }

    func testSolveResultValueSemantics() {
        let r1 = SolveResult(pose: Pose(locals: []), converged: true, iterations: 3, residual: 0.1)
        let r2 = SolveResult(pose: Pose(locals: []), converged: true, iterations: 3, residual: 0.1)
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(r1.iterations, 3)
    }
}
