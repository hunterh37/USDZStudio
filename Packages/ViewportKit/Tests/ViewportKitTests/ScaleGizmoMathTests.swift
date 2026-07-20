import Testing
import Foundation
import simd
@testable import ViewportKit

private typealias Ray = CameraRay.Ray

@Suite("Scale gizmo — handle hit-testing")
struct ScaleGizmoHitTests {

    private let origin = SIMD3<Double>.zero
    private let length = 1.0

    @Test func rayAtAxisHandleGrabsThatAxis() {
        let ray = Ray(origin: SIMD3(0.9, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: origin, length: length) == .axis(.x))
    }

    @Test func rayThroughTheCentreGrabsUniform() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: origin, length: length) == .uniform)
    }

    @Test func rayFarFromEverythingMisses() {
        let ray = Ray(origin: SIMD3(3, 3, 5), direction: SIMD3(0, 0, -1))
        #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: origin, length: length) == nil)
    }

    @Test func eachAxisHandleIsGrabbable() {
        let cases: [(ScaleHandle, Ray)] = [
            (.axis(.x), Ray(origin: SIMD3(0.9, 0, 5), direction: SIMD3(0, 0, -1))),
            (.axis(.y), Ray(origin: SIMD3(0, 0.9, 5), direction: SIMD3(0, 0, -1))),
            (.axis(.z), Ray(origin: SIMD3(5, 0, 0.9), direction: SIMD3(-1, 0, 0))),
        ]
        for (expected, ray) in cases {
            #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: origin, length: length) == expected)
        }
    }

    @Test func zeroLengthNeverHits() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: origin, length: 0) == nil)
    }

    @Test func respectsNonZeroOrigin() {
        let shifted = SIMD3<Double>(-3, 6, 2)
        let ray = Ray(origin: shifted + SIMD3(0.9, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: shifted, length: length) == .axis(.x))
    }

    @Test func nearestAxisWinsWhenTwoAreInReach() {
        // A ray near the shared origin but leaning toward +Y grabs the closest
        // axis handle, exercising the nearest-wins tie-break.
        let ray = Ray(origin: SIMD3(0.05, 0.35, 5), direction: SIMD3(0, 0, -1))
        #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: origin, length: length) == .axis(.y))
    }

    @Test func degenerateBasisAxisIsSkipped() {
        // A zero-length basis axis normalizes to itself and can't be grabbed;
        // the ray at the +X handle position still finds nothing on that axis.
        let basis = GizmoBasis(x: .zero, y: SIMD3(0, 1, 0), z: SIMD3(0, 0, 1))
        let ray = Ray(origin: SIMD3(0.9, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(ScaleGizmoMath.hitHandle(ray: ray, origin: origin, basis: basis, length: length) != .axis(.x))
    }
}

@Suite("Scale gizmo — drag factor")
struct ScaleGizmoFactorTests {

    @Test func doublingTheParameterDoublesTheFactor() {
        #expect(ScaleGizmoMath.factor(fromParam: 1.0, toParam: 2.0) == 2.0)
    }

    @Test func halvingTheParameterHalvesTheFactor() {
        #expect(ScaleGizmoMath.factor(fromParam: 2.0, toParam: 1.0) == 0.5)
    }

    @Test func unchangedParameterIsUnitFactor() {
        #expect(ScaleGizmoMath.factor(fromParam: 1.5, toParam: 1.5) == 1.0)
    }

    @Test func startParameterAtPivotReturnsNil() {
        #expect(ScaleGizmoMath.factor(fromParam: 0, toParam: 1) == nil)
    }
}
