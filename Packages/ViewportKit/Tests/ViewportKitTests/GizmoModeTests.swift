import Testing
import Foundation
import simd
@testable import ViewportKit

@Suite("Gizmo mode — W/E/R switch")
struct GizmoModeTests {

    @Test func shortcutsFollowTheMayaIdiom() {
        #expect(GizmoMode.translate.shortcut == "w")
        #expect(GizmoMode.rotate.shortcut == "e")
        #expect(GizmoMode.scale.shortcut == "r")
    }

    @Test func keysSelectTheirMode() {
        #expect(GizmoMode.forShortcut("w") == .translate)
        #expect(GizmoMode.forShortcut("e") == .rotate)
        #expect(GizmoMode.forShortcut("r") == .scale)
    }

    @Test func uppercaseKeysAlsoSelect() {
        #expect(GizmoMode.forShortcut("E") == .rotate)
    }

    @Test func unrelatedKeyIsNil() {
        #expect(GizmoMode.forShortcut("q") == nil)
    }
}

@Suite("Gizmo basis")
struct GizmoBasisTests {

    @Test func worldBasisIsIdentity() {
        #expect(GizmoBasis.world.direction(.x) == SIMD3(1, 0, 0))
        #expect(GizmoBasis.world.direction(.y) == SIMD3(0, 1, 0))
        #expect(GizmoBasis.world.direction(.z) == SIMD3(0, 0, 1))
    }

    @Test func directionSelectsTheNamedAxis() {
        let basis = GizmoBasis(x: SIMD3(2, 0, 0), y: SIMD3(0, 3, 0), z: SIMD3(0, 0, 4))
        #expect(basis.direction(.y) == SIMD3(0, 3, 0))
    }
}

/// Snapshot of the gizmo layout math per camera distance — every transform
/// gizmo shares one screen-constant sizing rule (`ExtrudeGizmoMath.handleLength`),
/// so translate arrows, rotate rings, and scale handles all track the camera
/// together. The rendering itself is coverage-disabled RealityKit; this pins
/// the geometry the hit-tests are computed against.
@Suite("Gizmo layout — screen-constant sizing per camera")
struct GizmoLayoutSnapshotTests {

    private let distances: [Double] = [0.5, 1, 2, 5, 12, 40]

    @Test func handleLengthScalesLinearlyWithCameraDistance() {
        for d in distances {
            let length = ExtrudeGizmoMath.handleLength(cameraDistance: d)
            #expect(abs(length - d * ExtrudeGizmoMath.lengthPerCameraDistance) < 1e-12)
        }
    }

    @Test func rotateRingRadiusTracksHandleLength() {
        for d in distances {
            let length = ExtrudeGizmoMath.handleLength(cameraDistance: d)
            let radius = length * RotateGizmoMath.radiusFraction
            // A ray grazing the rim at that radius grabs the ring; just inside
            // and outside the grab tolerance it does not.
            let onRim = CameraRay.Ray(origin: SIMD3(radius, 0, 10), direction: SIMD3(0, 0, -1))
            #expect(RotateGizmoMath.hitAxis(ray: onRim, origin: .zero, radius: radius) == .z)
            let outside = CameraRay.Ray(origin: SIMD3(radius * 1.5, 0, 10), direction: SIMD3(0, 0, -1))
            #expect(RotateGizmoMath.hitAxis(ray: outside, origin: .zero, radius: radius) == nil)
        }
    }

    @Test func scaleHandlesSitAtHandleLengthAcrossCameras() {
        for d in distances {
            let length = ExtrudeGizmoMath.handleLength(cameraDistance: d)
            // The axis handle tip is grabbable near its end; the centre stays
            // the uniform handle regardless of camera distance.
            let tip = CameraRay.Ray(origin: SIMD3(length * 0.9, 0, 10), direction: SIMD3(0, 0, -1))
            #expect(ScaleGizmoMath.hitHandle(ray: tip, origin: .zero, length: length) == .axis(.x))
            let centre = CameraRay.Ray(origin: SIMD3(0, 0, 10), direction: SIMD3(0, 0, -1))
            #expect(ScaleGizmoMath.hitHandle(ray: centre, origin: .zero, length: length) == .uniform)
        }
    }
}
