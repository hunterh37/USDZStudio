import Testing
import Foundation
import simd
import MechanismKit
@testable import ViewportKit

private typealias Ray = CameraRay.Ray

/// A revolute hinge about +Z through the origin, opening 0→105°.
private let hinge = Joint.openable(
    name: "lid", kind: .revolute, target: "Lid",
    axis: [0, 0, 1], pivot: [0, 0, 0], openValue: 105)

/// A prismatic drawer sliding along +X, 0→10 units.
private let drawer = Joint.openable(
    name: "drawer", kind: .prismatic, target: "Drawer",
    axis: [1, 0, 0], pivot: [0, 0, 0], openValue: 10)

@Suite("Hinge gizmo — knob placement")
struct HingeGizmoKnobTests {

    @Test func restArmIsPerpendicularToTheAxis() {
        let arm = HingeGizmoMath.restArm(axis: SIMD3(0, 0, 1))!
        #expect(abs(simd_dot(arm, SIMD3(0, 0, 1))) < 1e-9)
        #expect(abs(simd_length(arm) - 1) < 1e-9)
    }

    @Test func restArmWellConditionedForEachCardinalAxis() {
        for axis in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] {
            let arm = HingeGizmoMath.restArm(axis: axis)!
            #expect(abs(simd_dot(arm, simd_normalize(axis))) < 1e-9)
            #expect(abs(simd_length(arm) - 1) < 1e-9)
        }
    }

    @Test func degenerateAxisHasNoRestArm() {
        #expect(HingeGizmoMath.restArm(axis: .zero) == nil)
    }

    @Test func revoluteKnobSweepsAboutTheAxis() {
        // Closed knob at some perpendicular arm; a 90° pose rotates it a quarter
        // turn about +Z while staying at the same radius and z-height.
        let closed = HingeGizmoMath.knobPosition(
            origin: .zero, axis: SIMD3(0, 0, 1), kind: .revolute, value: 0, armLength: 2)!
        let open = HingeGizmoMath.knobPosition(
            origin: .zero, axis: SIMD3(0, 0, 1), kind: .revolute, value: 90, armLength: 2)!
        #expect(abs(simd_length(closed) - 2) < 1e-9)
        #expect(abs(simd_length(open) - 2) < 1e-9)
        #expect(abs(closed.z) < 1e-9 && abs(open.z) < 1e-9)
        // A quarter turn is orthogonal to the closed arm.
        #expect(abs(simd_dot(simd_normalize(closed), simd_normalize(open))) < 1e-9)
    }

    @Test func prismaticKnobSlidesAlongTheAxis() {
        let closed = HingeGizmoMath.knobPosition(
            origin: .zero, axis: SIMD3(1, 0, 0), kind: .prismatic, value: 0, armLength: 2)!
        let open = HingeGizmoMath.knobPosition(
            origin: .zero, axis: SIMD3(1, 0, 0), kind: .prismatic, value: 5, armLength: 2)!
        // Slid exactly 5 units along +X; the perpendicular arm is unchanged.
        #expect(simd_length((open - closed) - SIMD3(5, 0, 0)) < 1e-9)
    }

    @Test func degenerateAxisHasNoKnob() {
        #expect(HingeGizmoMath.knobPosition(
            origin: .zero, axis: .zero, kind: .revolute, value: 0, armLength: 2) == nil)
    }
}

@Suite("Hinge gizmo — grab")
struct HingeGizmoGrabTests {

    @Test func rayThroughTheKnobGrabsIt() {
        let knob = HingeGizmoMath.knobPosition(
            origin: .zero, axis: SIMD3(0, 0, 1), kind: .revolute, value: 0, armLength: 2)!
        let ray = Ray(origin: knob + SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(HingeGizmoMath.grabsKnob(
            ray: ray, origin: .zero, axis: SIMD3(0, 0, 1),
            kind: .revolute, value: 0, armLength: 2))
    }

    @Test func rayWideOfTheKnobMisses() {
        let ray = Ray(origin: SIMD3(50, 50, 5), direction: SIMD3(0, 0, -1))
        #expect(!HingeGizmoMath.grabsKnob(
            ray: ray, origin: .zero, axis: SIMD3(0, 0, 1),
            kind: .revolute, value: 0, armLength: 2))
    }

    @Test func zeroArmNeverGrabs() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(!HingeGizmoMath.grabsKnob(
            ray: ray, origin: .zero, axis: SIMD3(0, 0, 1),
            kind: .revolute, value: 0, armLength: 0))
    }

    @Test func degenerateAxisNeverGrabs() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(!HingeGizmoMath.grabsKnob(
            ray: ray, origin: .zero, axis: .zero,
            kind: .revolute, value: 0, armLength: 2))
    }

    @Test func distanceFallsBackToOriginForDegenerateRay() {
        // A zero-direction ray can't be projected onto; distance is measured to
        // the ray origin instead.
        let ray = Ray(origin: SIMD3(0, 0, 0), direction: .zero)
        let d = HingeGizmoMath.distance(from: SIMD3(3, 0, 0), to: ray)
        #expect(abs(d - 3) < 1e-9)
    }

    @Test func pointBehindTheRayMeasuresToTheOrigin() {
        // The knob sits behind the ray's start; the half-line clamps to s=0 so
        // the nearest point is the ray origin.
        let ray = Ray(origin: .zero, direction: SIMD3(0, 0, -1))
        let d = HingeGizmoMath.distance(from: SIMD3(0, 0, 4), to: ray)
        #expect(abs(d - 4) < 1e-9)
    }
}

@Suite("Hinge gizmo — drag to value")
struct HingeGizmoDragTests {

    @Test func revoluteSweepAddsToStartValueClampedHigh() {
        // Start arm at +X, drag to +Y → +90° about +Z. From a start value of 30
        // that would be 120°, past the 105° limit, so it clamps to 105.
        let start = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(0, 1, 5), direction: SIMD3(0, 0, -1))
        let v = HingeGizmoMath.draggedValue(
            joint: hinge, startValue: 30, origin: .zero, axis: SIMD3(0, 0, 1),
            startRay: start, currentRay: end)
        #expect(abs(v! - 105) < 1e-9)
    }

    @Test func revoluteWithinLimitsReturnsExactValue() {
        let start = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(0, 1, 5), direction: SIMD3(0, 0, -1))
        let v = HingeGizmoMath.draggedValue(
            joint: hinge, startValue: 0, origin: .zero, axis: SIMD3(0, 0, 1),
            startRay: start, currentRay: end)
        #expect(abs(v! - 90) < 1e-9)   // 0 + 90, inside [0,105]
    }

    @Test func revoluteNegativeSweepClampsLow() {
        // Sweep −90° from a start of 10 → −80, below the 0 lower limit → 0.
        let start = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(0, -1, 5), direction: SIMD3(0, 0, -1))
        let v = HingeGizmoMath.draggedValue(
            joint: hinge, startValue: 10, origin: .zero, axis: SIMD3(0, 0, 1),
            startRay: start, currentRay: end)
        #expect(abs(v!) < 1e-9)
    }

    @Test func revoluteUndefinedSweepReturnsNil() {
        // A start ray travelling within the ring plane never crosses it.
        let start = Ray(origin: SIMD3(1, 0, 0), direction: SIMD3(0, 1, 0))
        let end = Ray(origin: SIMD3(0, 1, 5), direction: SIMD3(0, 0, -1))
        #expect(HingeGizmoMath.draggedValue(
            joint: hinge, startValue: 0, origin: .zero, axis: SIMD3(0, 0, 1),
            startRay: start, currentRay: end) == nil)
    }

    @Test func prismaticDisplacementAddsAlongTheAxis() {
        // Two parallel down-rays crossing the X axis at x=2 and x=6 → +4 units.
        let start = Ray(origin: SIMD3(2, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(6, 0, 5), direction: SIMD3(0, 0, -1))
        let v = HingeGizmoMath.draggedValue(
            joint: drawer, startValue: 1, origin: .zero, axis: SIMD3(1, 0, 0),
            startRay: start, currentRay: end)
        #expect(abs(v! - 5) < 1e-9)   // 1 + 4
    }

    @Test func prismaticClampsToUpperLimit() {
        let start = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(20, 0, 5), direction: SIMD3(0, 0, -1))
        let v = HingeGizmoMath.draggedValue(
            joint: drawer, startValue: 0, origin: .zero, axis: SIMD3(1, 0, 0),
            startRay: start, currentRay: end)
        #expect(abs(v! - 10) < 1e-9)   // clamped to maxValue
    }

    @Test func prismaticRayParallelToAxisReturnsNil() {
        // Ray direction along the slide axis → no well-defined slide amount.
        let start = Ray(origin: SIMD3(0, 1, 0), direction: SIMD3(1, 0, 0))
        let end = Ray(origin: SIMD3(0, 1, 0), direction: SIMD3(1, 0, 0))
        #expect(HingeGizmoMath.draggedValue(
            joint: drawer, startValue: 0, origin: .zero, axis: SIMD3(1, 0, 0),
            startRay: start, currentRay: end) == nil)
    }

    @Test func prismaticDegenerateAxisReturnsNil() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(HingeGizmoMath.draggedValue(
            joint: drawer, startValue: 0, origin: .zero, axis: .zero,
            startRay: ray, currentRay: ray) == nil)
    }

    @Test func prismaticDegenerateRayDirectionReturnsNil() {
        let start = Ray(origin: SIMD3(2, 0, 5), direction: .zero)
        let end = Ray(origin: SIMD3(6, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(HingeGizmoMath.draggedValue(
            joint: drawer, startValue: 0, origin: .zero, axis: SIMD3(1, 0, 0),
            startRay: start, currentRay: end) == nil)
    }

    @Test func clampPassesThroughValuesInRange() {
        #expect(HingeGizmoMath.clamp(5, min: 0, max: 10) == 5)
        #expect(HingeGizmoMath.clamp(-1, min: 0, max: 10) == 0)
        #expect(HingeGizmoMath.clamp(11, min: 0, max: 10) == 10)
    }
}

@Suite("Hinge gizmo — descriptor")
struct HingeGizmoDescriptorTests {

    @Test func descriptorStoresGeometryAndJoint() {
        let d = HingeGizmoDescriptor(
            origin: SIMD3(1, 2, 3), axis: SIMD3(0, 0, 1), joint: hinge,
            value: 42, revision: 7)
        #expect(d.origin == SIMD3(1, 2, 3))
        #expect(d.joint == hinge)
        #expect(d.value == 42)
        #expect(d.revision == 7)
    }

    @Test func dragPhasesAreEquatable() {
        #expect(HingeGizmoDragPhase.began == .began)
        #expect(HingeGizmoDragPhase.changed(90) == .changed(90))
        #expect(HingeGizmoDragPhase.changed(90) != .changed(45))
        #expect(HingeGizmoDragPhase.ended != .began)
    }
}
