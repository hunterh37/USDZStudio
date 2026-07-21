import XCTest
import simd
@testable import MechanismKit

final class JointModelTests: XCTestCase {
    func testOpenableBuildsClosedAndOpenLoadingClosed() {
        let j = Joint.openable(name: "lid", kind: .revolute, target: "Lid",
                               axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 105)
        XCTAssertEqual(j.id, "lid")
        XCTAssertEqual(j.minValue, 0)
        XCTAssertEqual(j.maxValue, 105)
        XCTAssertEqual(j.defaultState, "closed")
        XCTAssertEqual(j.value(ofState: "closed"), 0)
        XCTAssertEqual(j.value(ofState: "open"), 105)
        XCTAssertNil(j.value(ofState: "nope"))
    }

    func testOpenableWithNegativeOpenValueOrdersLimits() {
        let j = Joint.openable(name: "hatch", kind: .revolute, target: "Hatch",
                               axis: [0, 0, 1], pivot: [0, 0, 0], openValue: -40)
        XCTAssertEqual(j.minValue, -40)
        XCTAssertEqual(j.maxValue, 0)
    }

    func testJointKindCaseCoverage() {
        XCTAssertEqual(Set(JointKind.allCases), [.revolute, .prismatic])
    }

    func testCodableRoundTrip() throws {
        let j = Joint.openable(name: "cap", kind: .prismatic, target: "Cap",
                               axis: [0, 1, 0], pivot: [0, 2, 0], openValue: 3)
        let data = try JSONEncoder().encode(j)
        XCTAssertEqual(try JSONDecoder().decode(Joint.self, from: data), j)
    }
}

final class PivotMathTests: XCTestCase {
    func testNormalizedAxisUnitLength() {
        let a = PivotMath.normalizedAxis([0, 3, 0])
        XCTAssertEqual(a.y, 1, accuracy: 1e-12)
        XCTAssertEqual(simd_length(a), 1, accuracy: 1e-12)
    }

    func testNormalizedAxisDegenerateFallsBackToY() {
        XCTAssertEqual(PivotMath.normalizedAxis([0, 0, 0]), SIMD3<Double>(0, 1, 0))
    }

    func testSimd3PadsShortArrays() {
        XCTAssertEqual(PivotMath.simd3([]), SIMD3<Double>(0, 0, 0))
        XCTAssertEqual(PivotMath.simd3([5]), SIMD3<Double>(5, 0, 0))
        XCTAssertEqual(PivotMath.simd3([5, 6]), SIMD3<Double>(5, 6, 0))
    }

    func testRotationIdentityAtZero() {
        let r = PivotMath.rotation(axis: [1, 0, 0], degrees: 0)
        XCTAssertLessThan(JointInvariants.maxComponentDifference(r, matrix_identity_double4x4), 1e-12)
    }

    func testRotation90AboutZMapsXToY() {
        let r = PivotMath.rotation(axis: [0, 0, 1], degrees: 90)
        let v = r * SIMD4<Double>(1, 0, 0, 1)
        XCTAssertEqual(v.x, 0, accuracy: 1e-9)
        XCTAssertEqual(v.y, 1, accuracy: 1e-9)
    }

    func testTranslation() {
        let t = PivotMath.translation(SIMD3<Double>(1, 2, 3))
        let v = t * SIMD4<Double>(0, 0, 0, 1)
        XCTAssertEqual(SIMD3<Double>(v.x, v.y, v.z), SIMD3<Double>(1, 2, 3))
    }

    func testPivotLocalRestIsTranslation() {
        let j = Joint.openable(name: "l", kind: .revolute, target: "L",
                               axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 90)
        let rest = PivotMath.pivotLocalMatrix(j, value: 0)
        let v = rest * SIMD4<Double>(0, 0, 0, 1)
        XCTAssertEqual(SIMD3<Double>(v.x, v.y, v.z), SIMD3<Double>(0, 1, 0))
    }

    func testPrismaticPivotSlidesAlongAxis() {
        let j = Joint.openable(name: "d", kind: .prismatic, target: "D",
                               axis: [1, 0, 0], pivot: [0, 0, 0], openValue: 4)
        let m = PivotMath.pivotLocalMatrix(j, value: 4)
        let v = m * SIMD4<Double>(0, 0, 0, 1)
        XCTAssertEqual(v.x, 4, accuracy: 1e-9)
    }

    func testChildWorldEqualsChildLocalAtRest() {
        let j = Joint.openable(name: "l", kind: .revolute, target: "L",
                               axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 90)
        let childLocal = PivotMath.translation(SIMD3<Double>(0, 2, 1))
        let composed = PivotMath.childWorldMatrix(j, value: 0, childLocal: childLocal)
        XCTAssertLessThan(JointInvariants.maxComponentDifference(composed, childLocal), 1e-9)
    }

    func testUsdRowMajorTransposesColumnVector() {
        let t = PivotMath.translation(SIMD3<Double>(1, 2, 3))
        let rm = PivotMath.usdRowMajor(t)
        // Row-major, row-vector USD matrix4d puts translation in the last row.
        XCTAssertEqual(Array(rm[12...15]), [1, 2, 3, 1])
    }

    func testRowMajorRoundTrip() {
        let m = PivotMath.translation(SIMD3<Double>(2, -1, 4))
            * PivotMath.rotation(axis: [0.3, 0.9, -0.2], degrees: 37)
        let back = PivotMath.fromUsdRowMajor(PivotMath.usdRowMajor(m))
        XCTAssertLessThan(JointInvariants.maxComponentDifference(back, m), 1e-12)
    }

    func testFromUsdRowMajorRejectsWrongLength() {
        XCTAssertLessThan(
            JointInvariants.maxComponentDifference(PivotMath.fromUsdRowMajor([1, 2, 3]),
                                                   matrix_identity_double4x4), 1e-12)
    }

    func testPivotTransformRowMajorRestIsTranslation() {
        let j = Joint.openable(name: "l", kind: .revolute, target: "L",
                               axis: [1, 0, 0], pivot: [0, 1, 2], openValue: 90)
        let rest = PivotMath.pivotTransformRowMajor(j, value: 0)
        XCTAssertEqual(Array(rest[12...15]), [0, 1, 2, 1])
    }

    func testPivotTransformForStateAndUnknownState() {
        let j = Joint.openable(name: "l", kind: .revolute, target: "L",
                               axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 90)
        XCTAssertNotNil(PivotMath.pivotTransformRowMajor(j, state: "open"))
        XCTAssertNil(PivotMath.pivotTransformRowMajor(j, state: "ajar"))
    }

    func testChildReparentRowMajorKeepsWorldAtRest() {
        let j = Joint.openable(name: "l", kind: .revolute, target: "L",
                               axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 90)
        let childLocal = PivotMath.usdRowMajor(PivotMath.translation(SIMD3<Double>(0, 2, 1)))
        let childReparent = PivotMath.childReparentRowMajor(j, childLocalRowMajor: childLocal)
        // pivot(rest) · childReparent == childLocal (world unchanged when closed)
        let composed = PivotMath.fromUsdRowMajor(PivotMath.pivotTransformRowMajor(j, value: 0))
            * PivotMath.fromUsdRowMajor(childReparent)
        XCTAssertLessThan(
            JointInvariants.maxComponentDifference(composed, PivotMath.fromUsdRowMajor(childLocal)), 1e-9)
    }
}

final class JointInvariantsTests: XCTestCase {
    private func valid() -> Joint {
        Joint.openable(name: "lid", kind: .revolute, target: "Lid",
                       axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 105)
    }

    func testValidJointHasNoErrors() {
        XCTAssertTrue(JointInvariants.isValid(valid()))
        XCTAssertTrue(JointInvariants.validate(valid()).isEmpty)
    }

    func testIdentifierValidator() {
        XCTAssertFalse(JointInvariants.isValidIdentifier(""))
        XCTAssertFalse(JointInvariants.isValidIdentifier("1bad"))
        XCTAssertFalse(JointInvariants.isValidIdentifier("has space"))
        XCTAssertTrue(JointInvariants.isValidIdentifier("_ok9"))
        XCTAssertTrue(JointInvariants.isValidIdentifier("Lid"))
    }

    func testInvalidNameAndTarget() {
        var j = valid(); j.name = "1x"; j.target = "bad name"
        let msgs = JointInvariants.validate(j).map(\.message).joined(separator: "|")
        XCTAssertTrue(msgs.contains("not a valid USD identifier"))
        XCTAssertFalse(JointInvariants.isValid(j))
    }

    func testAxisArityAndDegeneracy() {
        var j = valid(); j.axis = [1, 0]
        XCTAssertTrue(JointInvariants.validate(j).contains { $0.message.contains("axis must be") })
        j.axis = [0, 0, 0]
        XCTAssertTrue(JointInvariants.validate(j).contains { $0.message.contains("degenerate") })
    }

    func testPivotArity() {
        var j = valid(); j.pivot = [0, 1]
        XCTAssertTrue(JointInvariants.validate(j).contains { $0.message.contains("pivot must be") })
    }

    func testLimitOrdering() {
        var j = valid(); j.minValue = 10; j.maxValue = 5
        XCTAssertTrue(JointInvariants.validate(j).contains { $0.message.contains("exceeds maxValue") })
    }

    func testEmptyStates() {
        var j = valid(); j.states = []
        let msgs = JointInvariants.validate(j).map(\.message).joined(separator: "|")
        XCTAssertTrue(msgs.contains("declares no states"))
        XCTAssertTrue(msgs.contains("missing the required 'closed'"))
        XCTAssertTrue(msgs.contains("missing the required 'open'"))
    }

    func testDuplicateAndInvalidStateNames() {
        var j = valid()
        j.states = [JointState(name: "closed", value: 0),
                    JointState(name: "closed", value: 0),
                    JointState(name: "open", value: 10),
                    JointState(name: "bad name", value: 5)]
        j.maxValue = 10
        let msgs = JointInvariants.validate(j).map(\.message).joined(separator: "|")
        XCTAssertTrue(msgs.contains("duplicate state 'closed'"))
        XCTAssertTrue(msgs.contains("state name 'bad name'"))
    }

    func testStateOutOfRange() {
        var j = valid()
        j.states = [JointState(name: "closed", value: 0), JointState(name: "open", value: 999)]
        XCTAssertTrue(JointInvariants.validate(j).contains { $0.message.contains("outside limits") })
    }

    func testUnknownDefaultState() {
        var j = valid(); j.defaultState = "ajar"
        XCTAssertTrue(JointInvariants.validate(j).contains { $0.message.contains("names no declared state") })
    }

    func testAxisFixedPointResidualIsTiny() {
        XCTAssertLessThan(JointInvariants.axisFixedPointResidual(valid(), degrees: 73), 1e-9)
    }

    func testRestResidualIsTiny() {
        XCTAssertLessThan(JointInvariants.restResidual(valid()), 1e-12)
    }

    func testGeometryInPlaceResidualIsTiny() {
        let childLocal = PivotMath.translation(SIMD3<Double>(0.2, 2, -1))
        XCTAssertLessThan(JointInvariants.geometryInPlaceResidual(valid(), childLocal: childLocal), 1e-9)
    }

    func testPrismaticDisplacementMatchesValue() {
        let j = Joint.openable(name: "d", kind: .prismatic, target: "D",
                               axis: [0, 0, 2], pivot: [1, 1, 1], openValue: 3.5)
        let childLocal = PivotMath.translation(SIMD3<Double>(1, 0, 0))
        XCTAssertLessThan(JointInvariants.prismaticDisplacementError(j, value: 3.5, childLocal: childLocal), 1e-9)
    }

    /// Fuzz: over random axes / pivots / angles, the hinge line stays fixed and
    /// inserting the pivot never moves the closed geometry.
    func testFuzzAxisFixedPointAndGeometryInPlace() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            func r() -> Double { Double.random(in: -5...5, using: &rng) }
            let axis = [r(), r(), r()]
            guard simd_length(PivotMath.simd3(axis)) > 0.1 else { continue }
            let j = Joint.openable(name: "j", kind: .revolute, target: "T",
                                   axis: axis, pivot: [r(), r(), r()],
                                   openValue: Double.random(in: 1...179, using: &rng))
            let angle = Double.random(in: -180...180, using: &rng)
            XCTAssertLessThan(JointInvariants.axisFixedPointResidual(j, degrees: angle), 1e-6)
            let childLocal = PivotMath.translation(SIMD3<Double>(r(), r(), r()))
            XCTAssertLessThan(JointInvariants.geometryInPlaceResidual(j, childLocal: childLocal), 1e-6)
        }
    }
}

final class ArticulationManifestTests: XCTestCase {
    func testValidatedFromDropsInvalidJoints() {
        let good = Joint.openable(name: "lid", kind: .revolute, target: "Lid",
                                  axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 90)
        var bad = good; bad.name = "9bad"
        let m = ArticulationManifest(validatedFrom: [good, bad])
        XCTAssertEqual(m.joints.map(\.name), ["lid"])
        XCTAssertTrue(m.isActionable)
    }

    func testEmptyManifestNotActionable() {
        XCTAssertFalse(ArticulationManifest(joints: []).isActionable)
    }

    func testJSONIsDeterministicAndDecodes() throws {
        let j = Joint.openable(name: "lid", kind: .revolute, target: "Lid",
                               axis: [1, 0, 0], pivot: [0, 1, 0], openValue: 90)
        let m = ArticulationManifest(joints: [j])
        let json = try m.json()
        let decoded = try JSONDecoder().decode(ArticulationManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, m)
    }
}
