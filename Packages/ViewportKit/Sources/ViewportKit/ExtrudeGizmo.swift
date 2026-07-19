import Foundation

/// The extrude gizmo shown next to the selected face(s) in mesh edit mode:
/// a single arrow handle anchored at the selection centroid, pointing along
/// the extrude axis (the area-weighted averaged normal of the selection).
/// Dragging the handle extrudes live along that axis — the direct-manipulation
/// path next to the button/hotkey tools (specs/mesh-editing.md).
///
/// Pure data + pure math here; the RealityKit layer only draws the results
/// and forwards drag phases. Everything is unit-tested (ExtrudeGizmoMathTests).
public struct ExtrudeGizmoDescriptor: Equatable, Sendable {
    /// Handle anchor in prim-local space (selection centroid).
    public var origin: SIMD3<Double>
    /// Unit extrude axis in prim-local space.
    public var axis: SIMD3<Double>
    /// Bumped with the edited mesh so the viewport rebuilds in lockstep.
    public var revision: Int

    public init(origin: SIMD3<Double>, axis: SIMD3<Double>, revision: Int = 0) {
        self.origin = origin
        self.axis = axis
        self.revision = revision
    }
}

/// Drag lifecycle reported by the viewport while the user manipulates the
/// extrude handle. `changed` carries the signed distance along the gizmo axis
/// since `began` (positive = along the axis / outward).
public enum ExtrudeGizmoDragPhase: Equatable, Sendable {
    case began
    case changed(Double)
    case ended
}

/// Geometry of the arrow handle + the drag math, shared by rendering,
/// hit-testing, and screen-delta → distance conversion.
public enum ExtrudeGizmoMath {

    /// Handle shaft length as a fraction of camera distance — keeps the gizmo
    /// a constant apparent size on screen, the convention every major DCC
    /// (Blender / Maya / C4D) follows so the handle is always grabbable.
    public static let lengthPerCameraDistance = 0.16
    /// Grab radius around the handle segment, as a fraction of its length.
    /// Deliberately fat: a forgiving capsule is what makes dragging feel
    /// "smoother and easier" than pixel-perfect tips.
    public static let grabRadiusFraction = 0.22
    /// Tip sphere radius as a fraction of the shaft length.
    public static let tipRadiusFraction = 0.14
    /// Shaft thickness as a fraction of the shaft length.
    public static let shaftRadiusFraction = 0.035

    /// World-space shaft length for the current camera distance (clamped so a
    /// fully dollied-in camera can't collapse the handle to nothing).
    public static func handleLength(cameraDistance: Double) -> Double {
        max(cameraDistance, 1e-3) * lengthPerCameraDistance
    }

    /// Parameter `t` of the point on the axis line `origin + axis·t` closest
    /// to `ray` — the standard axis-constrained gizmo drag: each mouse ray is
    /// collapsed onto the axis, and the drag distance is the difference of
    /// parameters. `nil` when the ray is (numerically) parallel to the axis,
    /// where the closest point is unstable and a drag should freeze rather
    /// than jump.
    public static func axisParameter(ray: CameraRay.Ray, origin: SIMD3<Double>,
                                     axis: SIMD3<Double>) -> Double? {
        let d1 = axis, d2 = ray.direction
        let a = dot(d1, d1), b = dot(d1, d2), c = dot(d2, d2)
        let denom = a * c - b * b
        // Parallel (or degenerate axis/ray): |axis×dir|² == denom for unit
        // vectors; 1e-9 ≈ within ~0.002° of parallel.
        guard denom > 1e-9, a > 1e-12 else { return nil }
        let w = ray.origin - origin
        let d = dot(d1, w), e = dot(d2, w)
        return (c * d - b * e) / denom
    }

    /// Signed drag distance along the axis between two mouse rays. `nil`
    /// when either ray is parallel to the axis (caller keeps the last value).
    public static func dragDistance(from startRay: CameraRay.Ray, to currentRay: CameraRay.Ray,
                                    origin: SIMD3<Double>, axis: SIMD3<Double>) -> Double? {
        guard let t0 = axisParameter(ray: startRay, origin: origin, axis: axis),
              let t1 = axisParameter(ray: currentRay, origin: origin, axis: axis) else { return nil }
        return t1 - t0
    }

    /// Whether `ray` grabs the handle: distance between the ray and the shaft
    /// segment `[origin, origin + axis·length]` within the (fat) grab radius.
    /// Rays pointing away from the handle never hit.
    public static func hitTest(ray: CameraRay.Ray, origin: SIMD3<Double>,
                               axis: SIMD3<Double>, length: Double) -> Bool {
        guard length > 0 else { return false }
        let grabRadius = length * grabRadiusFraction
        return raySegmentDistance(ray: ray, a: origin, b: origin + axis * length) <= grabRadius
    }

    /// Minimum distance between a ray (t ≥ 0) and a segment. Closed-form
    /// closest-point-of-two-lines, with both parameters clamped to their
    /// valid ranges and re-projected (Ericson, Real-Time Collision Detection).
    static func raySegmentDistance(ray: CameraRay.Ray, a: SIMD3<Double>,
                                   b: SIMD3<Double>) -> Double {
        let seg = b - a
        let w = ray.origin - a
        let aa = dot(seg, seg)          // squared segment length
        let bb = dot(seg, ray.direction)
        let cc = dot(ray.direction, ray.direction)
        let dd = dot(seg, w)
        let ee = dot(ray.direction, w)
        let denom = aa * cc - bb * bb

        var s = denom > 1e-12 ? (cc * dd - bb * ee) / denom : 0 // on segment
        s = min(max(s, 0), 1)
        var t = cc > 1e-12 ? (bb * s - ee) / cc : 0             // on ray
        if t < 0 {                                              // ray starts past closest
            t = 0
            s = aa > 1e-12 ? min(max(dd / aa, 0), 1) : 0
        }
        let diff = (a + seg * s) - (ray.origin + ray.direction * t)
        return (diff * diff).sum().squareRoot()
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
