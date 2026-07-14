import Testing
import Foundation
@testable import ViewportKit

private func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

private func approx(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double = 1e-9) -> Bool {
    approx(a.x, b.x, tolerance: tolerance)
        && approx(a.y, b.y, tolerance: tolerance)
        && approx(a.z, b.z, tolerance: tolerance)
}

private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
private func length(_ v: SIMD3<Double>) -> Double { dot(v, v).squareRoot() }

@Suite("OrbitCamera basis")
struct CameraBasisTests {

    @Test func basisIsOrthonormal() {
        let camera = OrbitCamera(target: SIMD3(1, 2, 3), distance: 5, azimuth: 0.7, elevation: 0.4)
        let f = camera.forwardVector, r = camera.rightVector, u = camera.upVector
        #expect(approx(length(f), 1))
        #expect(approx(length(r), 1))
        #expect(approx(length(u), 1))
        #expect(approx(dot(f, r), 0))
        #expect(approx(dot(f, u), 0))
        #expect(approx(dot(r, u), 0))
    }

    @Test func defaultAzimuthLooksDownNegativeZ() {
        let camera = OrbitCamera(target: .zero, distance: 2, azimuth: 0, elevation: 0)
        #expect(approx(camera.forwardVector, SIMD3(0, 0, -1)))
        #expect(approx(camera.rightVector, SIMD3(1, 0, 0)))
        #expect(approx(camera.upVector, SIMD3(0, 1, 0)))
    }

    @Test func rightVectorStaysHorizontal() {
        let camera = OrbitCamera(azimuth: 1.2, elevation: 1.0)
        #expect(approx(camera.rightVector.y, 0))
    }

    @Test func panByScreenDeltaMatchesFocalPlaneScale() {
        var camera = OrbitCamera(target: .zero, distance: 2, azimuth: 0, elevation: 0)
        let height = 600.0
        let worldPerPoint = 2 * 2 * tan(OrbitCamera.verticalFOV / 2) / height
        camera.panByScreenDelta(deltaX: 0, deltaY: 10, viewportHeight: height)
        // Dragging up by 10 points moves the target up by 10 world-points.
        #expect(approx(camera.target, SIMD3(0, 10 * worldPerPoint, 0)))
    }

    @Test func panRespectsRightVector() {
        var camera = OrbitCamera(target: .zero, distance: 2, azimuth: 0, elevation: 0)
        camera.panByScreenDelta(deltaX: 10, deltaY: 0, viewportHeight: 600)
        // right = (1,0,0) at azimuth 0; content tracks the cursor, so the
        // target moves opposite the drag: +deltaX pans the target along -X.
        #expect(camera.target.x < 0)
        #expect(approx(camera.target.y, 0))
        #expect(approx(camera.target.z, 0))
    }

    @Test func panIgnoresDegenerateViewportHeight() {
        var camera = OrbitCamera()
        let before = camera
        camera.panByScreenDelta(deltaX: 5, deltaY: 5, viewportHeight: 0)
        #expect(camera == before)
    }

    @Test func fovIsSixtyDegrees() {
        #expect(approx(OrbitCamera.verticalFOV, .pi / 3))
    }
}

@Suite("GridModel")
struct GridModelTests {

    @Test func segmentCountAndAxes() {
        let segments = GridModel.segments(halfExtent: 5, divisions: 10)
        #expect(segments.count == 2 * (2 * 10 + 1))
        #expect(segments.filter(\.isAxis).count == 2)
    }

    @Test func segmentsSpanFullExtentOnGroundPlane() {
        let segments = GridModel.segments(halfExtent: 5, divisions: 4)
        for segment in segments {
            #expect(segment.start.y == 0 && segment.end.y == 0)
            #expect(abs(segment.length - 10) < 1e-5)
        }
    }

    @Test func midpointAndLength() {
        let segment = GridModel.Segment(start: SIMD3(-5, 0, 1), end: SIMD3(5, 0, 1), isAxis: false)
        #expect(segment.midpoint == SIMD3(0, 0, 1))
        #expect(abs(segment.length - 10) < 1e-6)
    }

    @Test func invalidInputsYieldEmptyGrid() {
        #expect(GridModel.segments(halfExtent: 0, divisions: 10).isEmpty)
        #expect(GridModel.segments(halfExtent: 5, divisions: 0).isEmpty)
        #expect(GridModel.segments(halfExtent: -1, divisions: 3).isEmpty)
    }

    @Test func fittingHalfExtentSnapsToNiceNumbers() {
        #expect(GridModel.fittingHalfExtent(forModelRadius: 0.4) == 1)   // needs 0.6 → 1
        #expect(GridModel.fittingHalfExtent(forModelRadius: 1.0) == 2)   // needs 1.5 → 2
        #expect(GridModel.fittingHalfExtent(forModelRadius: 3.0) == 5)   // needs 4.5 → 5
        #expect(GridModel.fittingHalfExtent(forModelRadius: 6.0) == 10)  // needs 9 → 10
        #expect(GridModel.fittingHalfExtent(forModelRadius: 60) == 100)
    }

    @Test func fittingHalfExtentHandlesDegenerateRadii() {
        #expect(GridModel.fittingHalfExtent(forModelRadius: 0) == 1)
        #expect(GridModel.fittingHalfExtent(forModelRadius: -3) == 1)
        #expect(GridModel.fittingHalfExtent(forModelRadius: .infinity) == 1)
        #expect(GridModel.fittingHalfExtent(forModelRadius: .nan) == 1)
    }
}

@Suite("SceneStats")
struct SceneStatsTests {

    @Test func countsLineGroupsAndPluralizes() {
        let stats = SceneStats(triangles: 12480, vertices: 6300, meshes: 3, materials: 2)
        #expect(stats.countsLine == "12,480 tris · 6,300 verts · 3 meshes · 2 materials")
    }

    @Test func countsLineSingular() {
        let stats = SceneStats(triangles: 2, vertices: 4, meshes: 1, materials: 1)
        #expect(stats.countsLine == "2 tris · 4 verts · 1 mesh · 1 material")
    }

    @Test func boundsLineUsesCentimetersBelowOneMeter() {
        let stats = SceneStats(boundsSize: SIMD3(0.25, 0.1, 0.05))
        #expect(stats.boundsLine == "bounds 25.0 × 10.0 × 5.0 cm")
    }

    @Test func boundsLineUsesMetersAtOrAboveOneMeter() {
        let stats = SceneStats(boundsSize: SIMD3(2, 1.5, 0.75))
        #expect(stats.boundsLine == "bounds 2.00 × 1.50 × 0.75 m")
    }

    @Test func boundsLineHandlesDegenerateBounds() {
        #expect(SceneStats(boundsSize: .zero).boundsLine == "bounds —")
        #expect(SceneStats(boundsSize: SIMD3(.nan, 1, 1)).boundsLine == "bounds —")
        #expect(SceneStats(boundsSize: SIMD3(.infinity, 1, 1)).boundsLine == "bounds —")
    }
}
