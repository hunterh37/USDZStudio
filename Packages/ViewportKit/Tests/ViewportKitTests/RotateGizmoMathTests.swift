import Testing
import Foundation
import simd
@testable import ViewportKit

private typealias Ray = CameraRay.Ray

@Suite("Rotate gizmo — ring hit-testing")
struct RotateGizmoHitTests {

    private let origin = SIMD3<Double>.zero
    private let radius = 1.0

    @Test func rayThroughTheZRingGrabsZ() {
        // Ring in the XY plane (normal +Z). A ray from +Z hitting the rim at
        // (1,0) grabs the Z ring.
        let ray = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: origin, radius: radius) == .z)
    }

    @Test func rayThroughTheXRingGrabsX() {
        // Ring in the YZ plane (normal +X); rim at (y,z)=(0,1) reached from +X.
        let ray = Ray(origin: SIMD3(5, 0, 1), direction: SIMD3(-1, 0, 0))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: origin, radius: radius) == .x)
    }

    @Test func rayThroughTheCentreMissesEveryRing() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: origin, radius: radius) == nil)
    }

    @Test func rayBeyondTheRimMisses() {
        let ray = Ray(origin: SIMD3(1.5, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: origin, radius: radius) == nil)
    }

    @Test func zeroRadiusNeverHits() {
        let ray = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: origin, radius: 0) == nil)
    }

    @Test func respectsNonZeroOrigin() {
        let shifted = SIMD3<Double>(4, -2, 7)
        let ray = Ray(origin: shifted + SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: shifted, radius: radius) == .z)
    }

    @Test func localBasisRemapsWhichRingIsGrabbed() {
        // A ray from +Z crossing the XY plane at (0,1,0) grabs the Z ring in
        // world orientation. Under a basis yawed 90° about Y (X now points
        // along world -Z), the ring lying in that XY plane is the X ring, so
        // the same ray grabs .x instead — the local frame remaps the axes.
        let ray = Ray(origin: SIMD3(0, 1, 5), direction: SIMD3(0, 0, -1))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: .zero, radius: radius) == .z)
        let basis = GizmoBasis(x: SIMD3(0, 0, -1), y: SIMD3(0, 1, 0), z: SIMD3(1, 0, 0))
        #expect(RotateGizmoMath.hitAxis(ray: ray, origin: .zero, basis: basis, radius: radius) == .x)
    }
}

@Suite("Rotate gizmo — swept angle")
struct RotateGizmoAngleTests {

    private let origin = SIMD3<Double>.zero

    @Test func quarterTurnAboutZMeasuresNinetyDegrees() {
        // In the XY plane: start pointing +X, end pointing +Y → +90° about +Z.
        let start = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(0, 1, 5), direction: SIMD3(0, 0, -1))
        let angle = RotateGizmoMath.signedAngleDegrees(from: start, to: end,
                                                       origin: origin, axis: SIMD3(0, 0, 1))
        #expect(abs(angle! - 90) < 1e-9)
    }

    @Test func oppositeSweepIsNegative() {
        let start = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        let end = Ray(origin: SIMD3(0, -1, 5), direction: SIMD3(0, 0, -1))
        let angle = RotateGizmoMath.signedAngleDegrees(from: start, to: end,
                                                       origin: origin, axis: SIMD3(0, 0, 1))
        #expect(abs(angle! + 90) < 1e-9)
    }

    @Test func noSweepIsZero() {
        let ray = Ray(origin: SIMD3(1, 0, 5), direction: SIMD3(0, 0, -1))
        let angle = RotateGizmoMath.signedAngleDegrees(from: ray, to: ray,
                                                       origin: origin, axis: SIMD3(0, 0, 1))
        #expect(abs(angle!) < 1e-9)
    }

    @Test func rayParallelToPlaneReturnsNil() {
        // Ray travelling within the ring's plane never crosses it.
        let start = Ray(origin: SIMD3(1, 0, 0), direction: SIMD3(0, 1, 0))
        let end = Ray(origin: SIMD3(0, 1, 5), direction: SIMD3(0, 0, -1))
        #expect(RotateGizmoMath.signedAngleDegrees(from: start, to: end,
                                                   origin: origin, axis: SIMD3(0, 0, 1)) == nil)
    }
}
