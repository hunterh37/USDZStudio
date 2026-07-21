import XCTest
@testable import RigKit

final class RigInvariantsTests: XCTestCase {
    func testSkeletonValidation() {
        XCTAssertTrue(RigInvariants.isValid(Fixtures.limb()))
        XCTAssertTrue(RigInvariants.validate(Fixtures.limb()).isEmpty)

        // Empty path.
        let emptyPath = Skeleton(joints: [RigJoint(id: "a", path: "", parent: nil, restLocal: .identity)])
        XCTAssertTrue(RigInvariants.validate(emptyPath).contains { $0.message.contains("empty path") })

        // Duplicate id.
        let dupe = Skeleton(joints: [
            RigJoint(id: "x", path: "a", parent: nil, restLocal: .identity),
            RigJoint(id: "x", path: "a/b", parent: 0, restLocal: .identity),
        ])
        XCTAssertTrue(RigInvariants.validate(dupe).contains { $0.message.contains("duplicate") })

        // Parent out of range.
        let oob = Skeleton(joints: [RigJoint(id: "a", path: "a", parent: 9, restLocal: .identity)])
        XCTAssertFalse(RigInvariants.isValid(oob))

        // Parent not topologically before (parent index >= own index).
        let unordered = Skeleton(joints: [
            RigJoint(id: "a", path: "a", parent: 1, restLocal: .identity),
            RigJoint(id: "b", path: "b", parent: nil, restLocal: .identity),
        ])
        XCTAssertTrue(RigInvariants.validate(unordered).contains { $0.message.contains("topologically") })
    }

    func testSkinInvariants() {
        let good = SkinBinding(perVertex: [[Influence(joint: 0, weight: 0.5), Influence(joint: 1, weight: 0.5)]])
        XCTAssertLessThan(RigInvariants.weightSumResidual(good), 1e-12)
        let bad = SkinBinding(perVertex: [[Influence(joint: 0, weight: 0.9)]])
        XCTAssertEqual(RigInvariants.weightSumResidual(bad), 0.1, accuracy: 1e-12)
        // Zero-weight vertex excluded from the residual.
        let zero = SkinBinding(perVertex: [[Influence(joint: 0, weight: 0)]])
        XCTAssertEqual(RigInvariants.weightSumResidual(zero), 0)
        XCTAssertTrue(RigInvariants.respectsInfluenceCap(good, cap: 4))
        XCTAssertFalse(RigInvariants.respectsInfluenceCap(good, cap: 1))
    }

    func testCanonicalStandardIsValid() {
        XCTAssertTrue(RigInvariants.validateCanonicalStandard().isEmpty)
    }

    func testCanonicalStandardFailureBranches() {
        // Duplicate name.
        let dup = [
            CanonicalBone(name: "Hips", side: .center, keywords: ["hips"]),
            CanonicalBone(name: "Hips", side: .center, keywords: ["hips"]),
        ]
        XCTAssertTrue(RigInvariants.validateCanonicalStandard(dup).contains { $0.message.contains("duplicate") })

        // Left bone with no right mirror.
        let noMirror = [CanonicalBone(name: "LeftArm", side: .left, keywords: ["arm"])]
        XCTAssertTrue(RigInvariants.validateCanonicalStandard(noMirror).contains { $0.message.contains("no right mirror") })

        // Mirror exists but keywords are asymmetric.
        let asym = [
            CanonicalBone(name: "LeftArm", side: .left, keywords: ["arm"]),
            CanonicalBone(name: "RightArm", side: .right, keywords: ["differs"]),
        ]
        XCTAssertTrue(RigInvariants.validateCanonicalStandard(asym).contains { $0.message.contains("asymmetric") })
    }

    func testMappingValidation() {
        let skel = SkelCorpus.mixamo
        let mapping = HumanoidMap.identify(skel)
        // A clean humanoid mapping has no errors (ancestry warnings only, if any).
        XCTAssertFalse(RigInvariants.validateMapping(mapping, skeleton: skel).contains { $0.severity == .error })

        // Force a double-claim: two canonical bones point at joint 0.
        var conflicting = mapping
        conflicting.matches["Hips"] = BoneMatch(jointIndex: 0, jointPath: "x", confidence: 1, alternates: [])
        conflicting.matches["Spine"] = BoneMatch(jointIndex: 0, jointPath: "x", confidence: 1, alternates: [])
        XCTAssertTrue(RigInvariants.validateMapping(conflicting, skeleton: skel).contains { $0.severity == .error })

        // Ancestry warning: Chest maps to a joint that isn't a descendant of Spine's joint.
        var broken = HumanoidMapping(matches: [
            "Spine": BoneMatch(jointIndex: 3, jointPath: "", confidence: 1, alternates: []),
            "Chest": BoneMatch(jointIndex: 1, jointPath: "", confidence: 1, alternates: []),
        ], lowConfidence: [])
        XCTAssertTrue(RigInvariants.validateMapping(broken, skeleton: skel).contains { $0.message.contains("ancestor") })
        broken.matches.removeAll()
        // Missing chain entries just skip (no crash).
        _ = RigInvariants.validateMapping(broken, skeleton: skel)
    }

    func testIssueEquatable() {
        XCTAssertEqual(RigIssue(.error, "m"), RigIssue(.error, "m"))
        XCTAssertNotEqual(RigIssue(.error, "m"), RigIssue(.warning, "m"))
    }
}

final class RigReviewGateTests: XCTestCase {
    func fullEvidence() -> RigEvidence {
        RigEvidence(hasRender: true, measuredMotionQuality: 0.9, subjectiveScore: 0.8)
    }

    func testAcceptsWhenAllHold() {
        let r = RigReviewGate.evaluate(decision: .continue, evidence: fullEvidence())
        XCTAssertTrue(r.accepted)
        XCTAssertTrue(r.reasons.isEmpty)
    }

    func testRejectsMissingRender() {
        var e = fullEvidence(); e.hasRender = false
        XCTAssertTrue(RigReviewGate.evaluate(decision: .continue, evidence: e).reasons.contains { $0.contains("render") })
    }

    func testRejectsBelowFloor() {
        var e = fullEvidence(); e.measuredMotionQuality = 0.1
        let r = RigReviewGate.evaluate(decision: .continue, evidence: e)
        XCTAssertFalse(r.accepted)
        XCTAssertTrue(r.reasons.contains { $0.contains("below floor") })
    }

    func testRejectsMissingMeasurement() {
        var e = fullEvidence(); e.measuredMotionQuality = nil
        XCTAssertTrue(RigReviewGate.evaluate(decision: .continue, evidence: e).reasons.contains { $0.contains("no assess_motion") })
    }

    func testRejectsMissingAndLowSubjective() {
        var e = fullEvidence(); e.subjectiveScore = nil
        XCTAssertTrue(RigReviewGate.evaluate(decision: .continue, evidence: e).reasons.contains { $0.contains("no subjective") })
        var low = fullEvidence(); low.subjectiveScore = 0.2
        XCTAssertTrue(RigReviewGate.evaluate(decision: .continue, evidence: low).reasons.contains { $0.contains("threshold") })
    }

    func testNonContinueDecisionsPassThrough() {
        for d in [RigDecision.refinePose, .resolve, .requestInput, .stop] {
            let r = RigReviewGate.evaluate(decision: d, evidence: RigEvidence(hasRender: false, measuredMotionQuality: nil, subjectiveScore: nil))
            XCTAssertTrue(r.accepted)
        }
    }

    func testDecisionAndTypesCodable() throws {
        XCTAssertEqual(RigDecision.allCases.count, 5)
        let d = try JSONEncoder().encode(RigDecision.resolve)
        XCTAssertEqual(try JSONDecoder().decode(RigDecision.self, from: d), .resolve)
        let e = try JSONEncoder().encode(fullEvidence())
        XCTAssertEqual(try JSONDecoder().decode(RigEvidence.self, from: e), fullEvidence())
        let g = try JSONEncoder().encode(RigGateResult(accepted: true, reasons: []))
        XCTAssertEqual(try JSONDecoder().decode(RigGateResult.self, from: g).accepted, true)
    }
}
