import Foundation

/// The object-mode rotate gizmo: three axis rings (X/Y/Z) centred on the
/// selection's world-space pivot — the standard DCC rotate gizmo. Dragging a
/// ring rotates the selection about that axis only, in either the world or the
/// selection's local basis.
///
/// Pure data + pure math here (same idiom as `TranslateGizmo`); the RealityKit
/// layer draws the rings and forwards drag phases up to the document, which
/// composes one coalesced undoable "Rotate".
public struct RotateGizmoDescriptor: Equatable, Sendable {
    /// The selection's pivot in world space.
    public var origin: SIMD3<Double>
    /// The basis the rings are drawn in (`world` or the selection's local axes).
    public var basis: GizmoBasis
    /// Bumped with the document so the viewport re-lays-out in lockstep.
    public var revision: Int

    public init(origin: SIMD3<Double>, basis: GizmoBasis = .world, revision: Int = 0) {
        self.origin = origin
        self.basis = basis
        self.revision = revision
    }
}

/// Drag lifecycle reported by the viewport while the user drags a ring.
/// `changed` carries the signed angle in **degrees** swept about the grabbed
/// axis since `began` (right-hand rule about the axis direction).
public enum RotateGizmoDragPhase: Equatable, Sendable {
    case began(GizmoAxis)
    case changed(GizmoAxis, Double)
    case ended
}

/// Ring hit-testing and swept-angle math for the rotate gizmo.
public enum RotateGizmoMath {

    /// Ring radius as a fraction of the shared handle length — a touch larger
    /// than the translate arrows so the rings enclose them.
    public static let radiusFraction = 1.0
    /// Grab tolerance around the ring, as a fraction of its radius: a ray whose
    /// plane-crossing lands within `radius·tolerance` of the ring grabs it.
    public static let grabToleranceFraction = 0.18

    /// World point where `ray` crosses the plane through `origin` with the
    /// given `normal`, or `nil` when the ray is (numerically) parallel to the
    /// plane, or the crossing is behind the ray origin.
    static func planeHit(ray: CameraRay.Ray, origin: SIMD3<Double>,
                         normal: SIMD3<Double>) -> SIMD3<Double>? {
        let denom = dot(normal, ray.direction)
        guard abs(denom) > 1e-9 else { return nil }
        let t = dot(normal, origin - ray.origin) / denom
        guard t >= 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    /// The axis whose ring `ray` grabs, or `nil` when it misses all three.
    /// Each ring lies in the plane normal to its axis; the ray is crossed with
    /// that plane and the crossing's distance from `origin` compared to the
    /// ring radius. When more than one ring is in reach, the closest wins.
    public static func hitAxis(ray: CameraRay.Ray, origin: SIMD3<Double>,
                               basis: GizmoBasis = .world, radius: Double) -> GizmoAxis? {
        guard radius > 0 else { return nil }
        let tolerance = radius * grabToleranceFraction
        var best: (axis: GizmoAxis, error: Double)?
        for axis in GizmoAxis.allCases {
            let normal = normalize(basis.direction(axis))
            guard let hit = planeHit(ray: ray, origin: origin, normal: normal) else { continue }
            let distance = length(hit - origin)
            let error = abs(distance - radius)
            guard error <= tolerance else { continue }
            if best == nil || error < best!.error { best = (axis, error) }
        }
        return best?.axis
    }

    /// The signed angle in degrees swept about `axis` between two mouse rays —
    /// each ray is crossed with the ring's plane and the angle between the two
    /// crossing directions (from `origin`) is measured with the right-hand
    /// rule about the axis. `nil` when either ray is parallel to the plane or a
    /// crossing coincides with the pivot (angle undefined); the caller keeps
    /// the last value.
    public static func signedAngleDegrees(from startRay: CameraRay.Ray,
                                          to currentRay: CameraRay.Ray,
                                          origin: SIMD3<Double>,
                                          axis: SIMD3<Double>) -> Double? {
        let normal = normalize(axis)
        guard let a = planeHit(ray: startRay, origin: origin, normal: normal),
              let b = planeHit(ray: currentRay, origin: origin, normal: normal) else { return nil }
        let va = a - origin, vb = b - origin
        guard length(va) > 1e-9, length(vb) > 1e-9 else { return nil }
        let cross = crossProduct(va, vb)
        let sin = dot(cross, normal)
        let cos = dot(va, vb)
        return atan2(sin, cos) * 180 / .pi
    }

    // MARK: SIMD helpers (kept local so the math file is self-contained)

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
    private static func length(_ v: SIMD3<Double>) -> Double { dot(v, v).squareRoot() }
    private static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = length(v)
        return l > 1e-12 ? v / l : v
    }
    private static func crossProduct(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y,
              a.z * b.x - a.x * b.z,
              a.x * b.y - a.y * b.x)
    }
}
