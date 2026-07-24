import Testing
import simd
@testable import ViewportKit

/// Pure camera math backing the unified (RealityKit) MCP snapshot renderer.
/// These must agree with the native SceneKit backend's framing, so they are
/// pinned here without any GPU.
@Suite("HeadlessCameraMath")
struct HeadlessCameraMathTests {

    private func approx(_ a: Double, _ b: Double, tol: Double = 1e-9) -> Bool {
        abs(a - b) <= tol
    }

    /// Vertical FOV matches the closed form the SceneKit renderer uses:
    /// 2·atan(aperture / (2·focal)).
    @Test func verticalFOVMatchesClosedForm() {
        let focal = 35.0
        let expected = 2 * atan(HeadlessCameraMath.verticalApertureMM / (2 * focal)) * 180 / .pi
        #expect(approx(HeadlessCameraMath.verticalFOVDegrees(focalLength: focal), expected))
    }

    /// Longer lenses are narrower: FOV is strictly decreasing in focal length.
    @Test func longerLensIsNarrower() {
        let wide = HeadlessCameraMath.verticalFOVDegrees(focalLength: 24)
        let tele = HeadlessCameraMath.verticalFOVDegrees(focalLength: 85)
        #expect(wide > tele)
    }

    /// A non-positive focal length is clamped (no divide-by-zero / no NaN).
    @Test func nonPositiveFocalIsClamped() {
        let fov = HeadlessCameraMath.verticalFOVDegrees(focalLength: 0)
        #expect(fov.isFinite && fov > 0)
    }

    /// The row-major USD transform maps onto simd columns with no transpose:
    /// each logical row becomes a column, and the eye row lands in column 3.
    @Test func cameraToWorldMapsRowsToColumns() {
        // Identity basis, eye at (1, 2, 3).
        let rows: [Double] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            1, 2, 3, 1,
        ]
        let m = HeadlessCameraMath.cameraToWorld(rowMajor: rows)
        #expect(m != nil)
        let matrix = m!
        #expect(matrix.columns.0 == SIMD4<Float>(1, 0, 0, 0))
        #expect(matrix.columns.1 == SIMD4<Float>(0, 1, 0, 0))
        #expect(matrix.columns.2 == SIMD4<Float>(0, 0, 1, 0))
        // Column 3 is the eye (translation) — the last logical row.
        #expect(matrix.columns.3 == SIMD4<Float>(1, 2, 3, 1))
    }

    /// Basis vectors survive verbatim (a non-identity orientation column).
    @Test func cameraToWorldPreservesBasis() {
        let rows: [Double] = [
            0, 0, -1, 0,   // xAxis
            0, 1, 0, 0,    // yAxis
            1, 0, 0, 0,    // zAxis
            5, 6, 7, 1,    // eye
        ]
        let matrix = HeadlessCameraMath.cameraToWorld(rowMajor: rows)!
        #expect(matrix.columns.0 == SIMD4<Float>(0, 0, -1, 0))
        #expect(matrix.columns.2 == SIMD4<Float>(1, 0, 0, 0))
        #expect(matrix.columns.3 == SIMD4<Float>(5, 6, 7, 1))
    }

    /// Anything but exactly 16 values is rejected rather than producing a
    /// garbage matrix.
    @Test func cameraToWorldRejectsWrongCount() {
        #expect(HeadlessCameraMath.cameraToWorld(rowMajor: []) == nil)
        #expect(HeadlessCameraMath.cameraToWorld(rowMajor: Array(repeating: 0, count: 15)) == nil)
        #expect(HeadlessCameraMath.cameraToWorld(rowMajor: Array(repeating: 0, count: 17)) == nil)
    }

#if canImport(RealityKit)
    /// The snapshot renderer constructs without a GPU (the GPU work is deferred
    /// to `renderPNG`), and its error cases are distinct. Covers the non-GPU
    /// surface of the renderer type; the render path itself is `coverage:disable`.
    @MainActor
    @Test func snapshotRendererConstructsAndErrorsAreDistinct() {
        _ = ViewportSnapshotRenderer()
        #expect(ViewportSnapshotRenderer.SnapshotError.noImage != .encodeFailed)
    }
#endif
}
