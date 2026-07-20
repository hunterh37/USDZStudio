import Testing
import Foundation
import simd
@testable import ViewportKit

private typealias Ray = CameraRay.Ray

@Suite("Translate gizmo — axis hit-testing")
struct TranslateGizmoHitTests {

    /// Gizmo at the origin, unit-length arrows.
    private let origin = SIMD3<Double>.zero
    private let length = 1.0

    @Test func rayAtArrowMidpointGrabsThatAxis() {
        // Fly past the middle of the +X arrow, looking down -Z.
        let ray = Ray(origin: SIMD3(0.5, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(TranslateGizmoMath.hitAxis(ray: ray, origin: origin, length: length) == .x)
    }

    @Test func eachAxisIsGrabbableAtItsTip() {
        let rays: [(GizmoAxis, Ray)] = [
            (.x, Ray(origin: SIMD3(0.9, 0, 5), direction: SIMD3(0, 0, -1))),
            (.y, Ray(origin: SIMD3(0, 0.9, 5), direction: SIMD3(0, 0, -1))),
            (.z, Ray(origin: SIMD3(5, 0, 0.9), direction: SIMD3(-1, 0, 0))),
        ]
        for (expected, ray) in rays {
            #expect(TranslateGizmoMath.hitAxis(ray: ray, origin: origin, length: length) == expected)
        }
    }

    @Test func rayFarFromAllArrowsMisses() {
        let ray = Ray(origin: SIMD3(3, 3, 5), direction: SIMD3(0, 0, -1))
        #expect(TranslateGizmoMath.hitAxis(ray: ray, origin: origin, length: length) == nil)
    }

    @Test func rayBeyondArrowLengthMisses() {
        // Past the tip (plus the grab capsule) along +X.
        let ray = Ray(origin: SIMD3(1.5, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(TranslateGizmoMath.hitAxis(ray: ray, origin: origin, length: length) == nil)
    }

    @Test func nearestAxisWinsNearTheSharedOrigin() {
        // Slightly closer to the Y arrow than the X arrow.
        let ray = Ray(origin: SIMD3(0.05, 0.12, 5), direction: SIMD3(0, 0, -1))
        #expect(TranslateGizmoMath.hitAxis(ray: ray, origin: origin, length: length) == .y)
    }

    @Test func respectsNonZeroOrigin() {
        let shifted = SIMD3<Double>(10, 2, -3)
        let ray = Ray(origin: shifted + SIMD3(0.5, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(TranslateGizmoMath.hitAxis(ray: ray, origin: shifted, length: length) == .x)
    }

    @Test func zeroLengthNeverHits() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(TranslateGizmoMath.hitAxis(ray: ray, origin: origin, length: 0) == nil)
    }

    @Test func axisDirectionsAreUnitAndOrthogonal() {
        for axis in GizmoAxis.allCases {
            #expect(abs(simd_length(axis.direction) - 1) < 1e-12)
        }
        #expect(simd_dot(GizmoAxis.x.direction, GizmoAxis.y.direction) == 0)
        #expect(simd_dot(GizmoAxis.y.direction, GizmoAxis.z.direction) == 0)
    }

    @Test func dragDistanceAlongGrabbedAxisMatchesMouseTravel() {
        // Two rays sweeping along +X should measure their X separation as the
        // drag distance (the same axisParameter math the extrude handle uses).
        let start = Ray(origin: SIMD3(0.2, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(0.9, 0, 5), direction: SIMD3(0, 0, -1))
        let t0 = ExtrudeGizmoMath.axisParameter(ray: start, origin: origin,
                                                axis: GizmoAxis.x.direction)
        let t1 = ExtrudeGizmoMath.axisParameter(ray: end, origin: origin,
                                                axis: GizmoAxis.x.direction)
        #expect(abs((t1! - t0!) - 0.7) < 1e-12)
    }
}
