import Foundation
import MechanismKit

/// The **drag-to-open handle** for a rigid articulation (a lid, door, cap,
/// drawer). Where the three transform gizmos edit a prim's own transform, this
/// overlay drives a *joint*: dragging its knob sweeps the moving part about the
/// hinge axis (revolute) or along the slide axis (prismatic), clamped to the
/// joint's limits.
///
/// It is deliberately the mechanical mirror of `RotateGizmo` — pure data + pure
/// math here; the RealityKit layer draws the knob and forwards drag phases up to
/// the document, which turns the reported value into one coalesced, undoable
/// `SetJointStateCommand` (the `setJointValue` document seam). The gizmo reads
/// the axis / pivot / limits straight off the `MechanismKit.Joint` authored on
/// the pivot Xform, so the handle can never drive the part outside its declared
/// range (specs/articulation-mechanisms.md — "hinge-axis gizmo overlay +
/// drag-to-open handle").
public struct HingeGizmoDescriptor: Equatable, Sendable {
    /// A point on the hinge/slide line, in **world** space (the pivot Xform's
    /// world-space origin — the caller maps the joint's root-local `pivot`
    /// through the pivot's world transform).
    public var origin: SIMD3<Double>
    /// The hinge/slide axis in **world** space. Need not be unit length; the
    /// math normalizes it (a degenerate zero axis simply yields no motion).
    public var axis: SIMD3<Double>
    /// The joint being driven — carries kind, limits, and named states.
    public var joint: Joint
    /// The joint's current value (degrees for `.revolute`, scene units for
    /// `.prismatic`) — where the handle sits along its travel right now.
    public var value: Double
    /// Bumped with the document so the viewport re-lays-out in lockstep.
    public var revision: Int

    public init(origin: SIMD3<Double>, axis: SIMD3<Double>, joint: Joint,
                value: Double, revision: Int = 0) {
        self.origin = origin
        self.axis = axis
        self.joint = joint
        self.value = value
        self.revision = revision
    }
}

/// Drag lifecycle reported by the viewport while the user drags the hinge knob.
/// `changed` carries the **new, clamped joint value** (degrees or units) — the
/// exact number the document hands to `SetJointStateCommand.make(pivotPath:
/// value:)`, so the pivot can never be driven past its limits.
public enum HingeGizmoDragPhase: Equatable, Sendable {
    case began
    case changed(Double)
    case ended
}

/// Knob placement, hit-testing, and drag→value math for the hinge handle. Pure
/// functions on value types (the `RotateGizmo`/`TranslateGizmo` idiom), so the
/// whole seam is unit-testable without a GPU.
public enum HingeGizmoMath {

    /// Grab tolerance around the knob as a fraction of the arm length: a pick
    /// ray passing within `armLength · grabToleranceFraction` of the knob
    /// grabs it.
    public static let grabToleranceFraction = 0.22

    // MARK: Knob placement

    /// A deterministic unit vector perpendicular to `axis`, used as the rest
    /// (closed-pose) direction of the handle arm. Built from whichever world
    /// axis is *least* aligned with the hinge, so it is always well-conditioned
    /// even when the hinge runs along X, Y, or Z. Returns `nil` for a
    /// degenerate (zero-length) axis.
    public static func restArm(axis: SIMD3<Double>) -> SIMD3<Double>? {
        let a = normalize(axis)
        guard length(a) > 1e-9 else { return nil }
        // Pick the cardinal direction most orthogonal to the axis (smallest
        // absolute component) so the cross product is far from degenerate.
        let ax = abs(a.x), ay = abs(a.y), az = abs(a.z)
        let cardinal: SIMD3<Double>
        if ax <= ay && ax <= az { cardinal = SIMD3(1, 0, 0) }
        else if ay <= az { cardinal = SIMD3(0, 1, 0) }
        else { cardinal = SIMD3(0, 0, 1) }
        let perp = cardinal - a * dot(cardinal, a)
        let l = length(perp)
        guard l > 1e-9 else { return nil }
        return perp / l
    }

    /// World-space position of the handle knob for a joint at `value`, on an arm
    /// of length `armLength` from `origin`. For a revolute joint the rest arm is
    /// rotated about the axis by `value` degrees (so the knob tracks the swing);
    /// for a prismatic joint the arm stays put and the knob slides `value` units
    /// along the axis. Returns `nil` for a degenerate axis.
    public static func knobPosition(origin: SIMD3<Double>, axis: SIMD3<Double>,
                                    kind: JointKind, value: Double,
                                    armLength: Double) -> SIMD3<Double>? {
        guard let rest = restArm(axis: axis) else { return nil }
        let a = normalize(axis)
        switch kind {
        case .revolute:
            let arm = rotate(rest, about: a, degrees: value)
            return origin + arm * armLength
        case .prismatic:
            return origin + rest * armLength + a * value
        }
    }

    /// Shortest distance from `point` to the pick `ray` (treated as a half-line
    /// from its origin), used to grab the knob.
    public static func distance(from point: SIMD3<Double>, to ray: CameraRay.Ray) -> Double {
        let dir = normalize(ray.direction)
        guard length(dir) > 1e-9 else { return length(point - ray.origin) }
        let s = max(0, dot(point - ray.origin, dir))
        let closest = ray.origin + dir * s
        return length(point - closest)
    }

    /// Whether `ray` grabs the hinge knob for the given descriptor geometry.
    public static func grabsKnob(ray: CameraRay.Ray, origin: SIMD3<Double>,
                                 axis: SIMD3<Double>, kind: JointKind,
                                 value: Double, armLength: Double) -> Bool {
        guard armLength > 0,
              let knob = knobPosition(origin: origin, axis: axis, kind: kind,
                                      value: value, armLength: armLength) else { return false }
        return distance(from: knob, to: ray) <= armLength * grabToleranceFraction
    }

    // MARK: Drag → value

    /// The new joint value produced by dragging from `startRay` to `currentRay`,
    /// starting at `startValue`, **clamped to the joint's limits**. Revolute
    /// measures the signed angle swept about the axis (reusing the rotate
    /// gizmo's plane-crossing math); prismatic measures displacement along the
    /// axis. Returns `nil` when the drag is undefined this frame (ray parallel
    /// to the motion, crossing at the pivot) — the caller keeps the last value.
    public static func draggedValue(joint: Joint, startValue: Double,
                                    origin: SIMD3<Double>, axis: SIMD3<Double>,
                                    startRay: CameraRay.Ray,
                                    currentRay: CameraRay.Ray) -> Double? {
        let delta: Double?
        switch joint.kind {
        case .revolute:
            delta = RotateGizmoMath.signedAngleDegrees(
                from: startRay, to: currentRay, origin: origin, axis: axis)
        case .prismatic:
            let a = normalize(axis)
            guard length(a) > 1e-9,
                  let tStart = axisParam(of: startRay, origin: origin, axis: a),
                  let tCurrent = axisParam(of: currentRay, origin: origin, axis: a)
            else { return nil }
            delta = tCurrent - tStart
        }
        guard let delta else { return nil }
        return clamp(startValue + delta, min: joint.minValue, max: joint.maxValue)
    }

    /// Parameter `t` such that `origin + t·axis` is the point on the slide line
    /// closest to `ray` (the standard line–line closest approach). `nil` when
    /// the ray is parallel to the axis (no well-defined slide amount).
    static func axisParam(of ray: CameraRay.Ray, origin: SIMD3<Double>,
                          axis: SIMD3<Double>) -> Double? {
        let d1 = axis                       // assumed unit (caller normalizes)
        let d2 = normalize(ray.direction)
        guard length(d2) > 1e-9 else { return nil }
        let w0 = origin - ray.origin
        let b = dot(d1, d2)
        let denom = 1 - b * b               // a·c - b² with a = c-component pre-normalized
        guard abs(denom) > 1e-9 else { return nil }
        let d = dot(d1, w0)
        let e = dot(d2, w0)
        return (b * e - d) / denom
    }

    // MARK: Local vector helpers (kept self-contained, matching RotateGizmo)

    static func clamp(_ v: Double, min lo: Double, max hi: Double) -> Double {
        v < lo ? lo : (v > hi ? hi : v)
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
    private static func length(_ v: SIMD3<Double>) -> Double { dot(v, v).squareRoot() }
    private static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = length(v)
        return l > 1e-12 ? v / l : v
    }
    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y,
              a.z * b.x - a.x * b.z,
              a.x * b.y - a.y * b.x)
    }
    /// Rodrigues rotation of `v` about unit `k` by `degrees`.
    private static func rotate(_ v: SIMD3<Double>, about k: SIMD3<Double>,
                               degrees: Double) -> SIMD3<Double> {
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        return v * c + cross(k, v) * s + k * (dot(k, v) * (1 - c))
    }
}
