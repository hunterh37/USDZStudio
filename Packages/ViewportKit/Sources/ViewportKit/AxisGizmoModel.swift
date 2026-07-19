import Foundation

/// Pure math for the corner orientation gizmo (specs/viewport.md "gizmos" /
/// ortho presets): projects the six world half-axes into 2D through the
/// orbit-camera basis, hit-tests tip clicks, and maps each half-axis to the
/// orbit angles that look down it. The SwiftUI layer only draws the results.
public enum AxisGizmoModel {

    /// One of the six world half-axes shown by the gizmo.
    public enum HalfAxis: CaseIterable, Hashable, Sendable {
        case xPositive, xNegative, yPositive, yNegative, zPositive, zNegative

        /// World-space unit direction.
        public var direction: SIMD3<Double> {
            switch self {
            case .xPositive: SIMD3(1, 0, 0)
            case .xNegative: SIMD3(-1, 0, 0)
            case .yPositive: SIMD3(0, 1, 0)
            case .yNegative: SIMD3(0, -1, 0)
            case .zPositive: SIMD3(0, 0, 1)
            case .zNegative: SIMD3(0, 0, -1)
            }
        }

        public var isPositive: Bool {
            switch self {
            case .xPositive, .yPositive, .zPositive: true
            default: false
            }
        }

        /// Axis letter for the tip label ("X"/"Y"/"Z").
        public var label: String {
            switch self {
            case .xPositive, .xNegative: "X"
            case .yPositive, .yNegative: "Y"
            case .zPositive, .zNegative: "Z"
            }
        }
    }

    /// A half-axis projected into gizmo-local 2D coordinates.
    public struct Tip: Hashable, Sendable {
        public let axis: HalfAxis
        /// Offset from the gizmo center, +x right / +y down (screen space),
        /// in units of the gizmo radius (so |offset| ≤ 1).
        public let offsetX: Double
        public let offsetY: Double
        /// Signed depth along the view direction: positive = beyond the
        /// gizmo center (far side), negative = toward the viewer.
        public let depth: Double
    }

    /// The six tips for the given camera orientation, sorted back-to-front
    /// (draw in order; hit-test in reverse).
    public static func tips(camera: OrbitCamera) -> [Tip] {
        let right = camera.rightVector
        let up = camera.upVector
        let forward = camera.forwardVector
        return HalfAxis.allCases.map { axis in
            let d = axis.direction
            return Tip(
                axis: axis,
                offsetX: dot(d, right),
                offsetY: -dot(d, up),
                depth: dot(d, forward))
        }
        .sorted { $0.depth > $1.depth }
    }

    /// The tip under `point` (gizmo-local, same units as `Tip` offsets scaled
    /// by `radius`), front-most first, within `hitRadius` of a tip center.
    public static func hitTest(x: Double, y: Double, radius: Double,
                               hitRadius: Double, camera: OrbitCamera) -> HalfAxis? {
        guard radius > 0 else { return nil }
        for tip in tips(camera: camera).reversed() { // front-most first
            let dx = x - tip.offsetX * radius
            let dy = y - tip.offsetY * radius
            if (dx * dx + dy * dy).squareRoot() <= hitRadius { return tip.axis }
        }
        return nil
    }

    /// Orbit angles that view the target from the clicked half-axis side
    /// (clicking +X looks down −X from the right, etc.). Top/bottom views
    /// keep the current azimuth so the turntable doesn't spin underfoot;
    /// elevation clamps shy of the pole per `OrbitCamera.elevationLimit`.
    public static func preset(for axis: HalfAxis,
                              currentAzimuth: Double) -> (azimuth: Double, elevation: Double) {
        switch axis {
        case .xPositive: (.pi / 2, 0)
        case .xNegative: (-.pi / 2, 0)
        case .zPositive: (0, 0)
        case .zNegative: (.pi, 0)
        case .yPositive: (currentAzimuth, OrbitCamera.elevationLimit)
        case .yNegative: (currentAzimuth, -OrbitCamera.elevationLimit)
        }
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
