import Testing
import Foundation
import simd
@testable import ViewportKit

private typealias Ray = CameraRay.Ray
private typealias Math = ExtrudeGizmoMath

/// A ray looking down -X at the given height/depth, hitting the YZ plane.
private func rayTowardYAxis(y: Double, z: Double = 0) -> Ray {
    Ray(origin: SIMD3(5, y, z), direction: SIMD3(-1, 0, 0))
}

@Suite("Extrude gizmo — axis parameter (drag math)")
struct AxisParameterTests {

    @Test func perpendicularRayLandsOnItsHeight() {
        // Axis +Y through the origin; a ray flying past at y=2 is closest to
        // the axis exactly at t=2.
        let t = Math.axisParameter(ray: rayTowardYAxis(y: 2),
                                   origin: .zero, axis: SIMD3(0, 1, 0))
        #expect(t != nil)
        #expect(abs(t! - 2) < 1e-12)
    }

    @Test func parameterIsRelativeToOrigin() {
        let t = Math.axisParameter(ray: rayTowardYAxis(y: 2),
                                   origin: SIMD3(0, 1.5, 0), axis: SIMD3(0, 1, 0))
        #expect(abs(t! - 0.5) < 1e-12)
    }

    @Test func negativeSideGivesNegativeParameter() {
        let t = Math.axisParameter(ray: rayTowardYAxis(y: -3),
                                   origin: .zero, axis: SIMD3(0, 1, 0))
        #expect(abs(t! + 3) < 1e-12)
    }

    @Test func obliqueRayStillProjectsCorrectly() {
        // Ray through (0, 4, 0) diagonal in XZ: closest point on the Y axis
        // is still y=4 (direction has no Y component).
        let d = simd_normalize(SIMD3<Double>(-1, 0, 0.5))
        let ray = Ray(origin: SIMD3(3, 4, -1.5), direction: d)
        let t = Math.axisParameter(ray: ray, origin: .zero, axis: SIMD3(0, 1, 0))
        #expect(abs(t! - 4) < 1e-9)
    }

    @Test func parallelRayIsRejected() {
        let ray = Ray(origin: SIMD3(1, 0, 0), direction: SIMD3(0, 1, 0))
        #expect(Math.axisParameter(ray: ray, origin: .zero, axis: SIMD3(0, 1, 0)) == nil)
    }

    @Test func nearParallelRayIsRejectedNotUnstable() {
        // Within ~0.002° of parallel: must refuse rather than return a huge
        // unstable parameter (the drag freezes instead of jumping).
        let d = simd_normalize(SIMD3<Double>(1e-6, 1, 0))
        let ray = Ray(origin: SIMD3(1, 0, 0), direction: d)
        #expect(Math.axisParameter(ray: ray, origin: .zero, axis: SIMD3(0, 1, 0)) == nil)
    }

    @Test func dragDistanceIsParameterDelta() {
        let d = Math.dragDistance(from: rayTowardYAxis(y: 1), to: rayTowardYAxis(y: 3.5),
                                  origin: .zero, axis: SIMD3(0, 1, 0))
        #expect(abs(d! - 2.5) < 1e-12)
    }

    @Test func dragDistanceIsSignedAndSymmetric() {
        let forward = Math.dragDistance(from: rayTowardYAxis(y: 1), to: rayTowardYAxis(y: 0),
                                        origin: .zero, axis: SIMD3(0, 1, 0))!
        let backward = Math.dragDistance(from: rayTowardYAxis(y: 0), to: rayTowardYAxis(y: 1),
                                         origin: .zero, axis: SIMD3(0, 1, 0))!
        #expect(abs(forward + 1) < 1e-12)
        #expect(abs(forward + backward) < 1e-12)
    }
}

@Suite("Extrude gizmo — handle hit-testing")
struct GizmoHitTestTests {

    private let origin = SIMD3<Double>.zero
    private let axis = SIMD3<Double>(0, 1, 0)

    @Test func rayThroughShaftHits() {
        #expect(Math.hitTest(ray: rayTowardYAxis(y: 0.5), origin: origin, axis: axis, length: 1))
    }

    @Test func rayThroughTipHits() {
        #expect(Math.hitTest(ray: rayTowardYAxis(y: 1.0), origin: origin, axis: axis, length: 1))
    }

    @Test func rayInsideGrabRadiusHits() {
        let radius = Math.grabRadiusFraction // length 1 → world grab radius
        #expect(Math.hitTest(ray: rayTowardYAxis(y: 0.5, z: radius * 0.9),
                             origin: origin, axis: axis, length: 1))
    }

    @Test func rayOutsideGrabRadiusMisses() {
        let radius = Math.grabRadiusFraction
        #expect(!Math.hitTest(ray: rayTowardYAxis(y: 0.5, z: radius * 1.5),
                              origin: origin, axis: axis, length: 1))
    }

    @Test func rayBeyondTipMisses() {
        #expect(!Math.hitTest(ray: rayTowardYAxis(y: 1 + Math.grabRadiusFraction * 2),
                              origin: origin, axis: axis, length: 1))
    }

    @Test func rayPointingAwayMisses() {
        let ray = Ray(origin: SIMD3(5, 0.5, 0), direction: SIMD3(1, 0, 0))
        #expect(!Math.hitTest(ray: ray, origin: origin, axis: axis, length: 1))
    }

    @Test func zeroLengthHandleNeverHits() {
        #expect(!Math.hitTest(ray: rayTowardYAxis(y: 0), origin: origin, axis: axis, length: 0))
    }

    @Test func hitScalesWithHandleLength() {
        // Same ray offset: inside the fat radius of a long handle, outside a
        // short one — grab difficulty stays constant on screen.
        let offset = 0.15
        #expect(Math.hitTest(ray: rayTowardYAxis(y: 0.5, z: offset),
                             origin: origin, axis: axis, length: 1))
        #expect(!Math.hitTest(ray: rayTowardYAxis(y: 0.05, z: offset),
                              origin: origin, axis: axis, length: 0.2))
    }
}

@Suite("Extrude gizmo — ray/segment distance")
struct RaySegmentDistanceTests {

    private let a = SIMD3<Double>.zero
    private let b = SIMD3<Double>(0, 1, 0)

    @Test func perpendicularMidpointDistanceIsExact() {
        let d = Math.raySegmentDistance(ray: rayTowardYAxis(y: 0.5, z: 0.25), a: a, b: b)
        #expect(abs(d - 0.25) < 1e-12)
    }

    @Test func clampsToSegmentEnd() {
        // Ray passes at y=3; closest segment point is the end (0,1,0).
        let d = Math.raySegmentDistance(ray: rayTowardYAxis(y: 3), a: a, b: b)
        #expect(abs(d - 2) < 1e-12)
    }

    @Test func clampsToRayStartWhenPointingAway() {
        let ray = Ray(origin: SIMD3(2, 0.5, 0), direction: SIMD3(1, 0, 0))
        let d = Math.raySegmentDistance(ray: ray, a: a, b: b)
        #expect(abs(d - 2) < 1e-12)
    }

    @Test func parallelRayDistanceIsPerpendicularGap() {
        let ray = Ray(origin: SIMD3(0.5, -5, 0), direction: SIMD3(0, 1, 0))
        let d = Math.raySegmentDistance(ray: ray, a: a, b: b)
        #expect(abs(d - 0.5) < 1e-9)
    }

    @Test func degenerateSegmentIsPointDistance() {
        let d = Math.raySegmentDistance(ray: rayTowardYAxis(y: 0, z: 0.3), a: a, b: a)
        #expect(abs(d - 0.3) < 1e-12)
    }
}

@Suite("Extrude gizmo — screen-constant sizing")
struct GizmoSizingTests {

    @Test func lengthScalesWithCameraDistance() {
        #expect(abs(Math.handleLength(cameraDistance: 2)
                    - 2 * Math.lengthPerCameraDistance) < 1e-12)
        #expect(Math.handleLength(cameraDistance: 10) > Math.handleLength(cameraDistance: 1))
    }

    @Test func lengthNeverCollapsesToZero() {
        #expect(Math.handleLength(cameraDistance: 0) > 0)
        #expect(Math.handleLength(cameraDistance: -5) > 0)
    }
}
