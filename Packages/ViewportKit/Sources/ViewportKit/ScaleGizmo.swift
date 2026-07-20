import Foundation

/// A scale-gizmo handle: one of the three per-axis box handles, or the central
/// uniform (all-axis) handle.
public enum ScaleHandle: Equatable, Hashable, Sendable {
    case axis(GizmoAxis)
    case uniform
}

/// The object-mode scale gizmo: three per-axis box handles (X/Y/Z) plus a
/// central uniform handle, at the selection's world-space pivot — the standard
/// DCC scale gizmo. Dragging a per-axis handle scales along that axis only;
/// dragging the centre scales uniformly.
///
/// Pure data + pure math here (same idiom as `TranslateGizmo`); the RealityKit
/// layer draws the boxes and forwards drag phases up to the document, which
/// composes one coalesced undoable "Scale" with parent-space correctness.
public struct ScaleGizmoDescriptor: Equatable, Sendable {
    /// The selection's pivot in world space.
    public var origin: SIMD3<Double>
    /// The basis the per-axis handles point along.
    public var basis: GizmoBasis
    /// Bumped with the document so the viewport re-lays-out in lockstep.
    public var revision: Int

    public init(origin: SIMD3<Double>, basis: GizmoBasis = .world, revision: Int = 0) {
        self.origin = origin
        self.basis = basis
        self.revision = revision
    }
}

/// Drag lifecycle reported by the viewport while the user drags a handle.
/// `changed` carries the multiplicative scale factor relative to the drag
/// start (`1` = unchanged, `2` = doubled, `0.5` = halved).
public enum ScaleGizmoDragPhase: Equatable, Sendable {
    case began(ScaleHandle)
    case changed(ScaleHandle, Double)
    case ended
}

/// Hit-testing and drag-factor math for the scale gizmo. The per-axis handles
/// reuse the arrow segment math (`ExtrudeGizmoMath`); the uniform handle is a
/// small sphere at the pivot.
public enum ScaleGizmoMath {

    /// Uniform (centre) handle radius as a fraction of the shared handle
    /// length — deliberately generous so the centre stays easy to grab.
    public static let uniformRadiusFraction = 0.18

    /// The handle `ray` grabs, or `nil` when it misses everything. The uniform
    /// centre wins ties near the pivot; otherwise the nearest axis handle is
    /// returned (same fat capsule as the translate arrows).
    public static func hitHandle(ray: CameraRay.Ray, origin: SIMD3<Double>,
                                 basis: GizmoBasis = .world, length: Double) -> ScaleHandle? {
        guard length > 0 else { return nil }
        let uniformRadius = length * uniformRadiusFraction
        // Distance from the ray to the pivot point (degenerate segment).
        let centreDistance = ExtrudeGizmoMath.raySegmentDistance(ray: ray, a: origin, b: origin)
        var best: (handle: ScaleHandle, distance: Double)?
        if centreDistance <= uniformRadius { best = (.uniform, centreDistance) }

        let grabRadius = length * ExtrudeGizmoMath.grabRadiusFraction
        for axis in GizmoAxis.allCases {
            let dir = normalize(basis.direction(axis))
            let d = ExtrudeGizmoMath.raySegmentDistance(ray: ray, a: origin, b: origin + dir * length)
            guard d <= grabRadius else { continue }
            if best == nil || d < best!.distance { best = (.axis(axis), d) }
        }
        return best?.handle
    }

    /// The scale factor for a handle dragged along its axis from `startParam`
    /// to `currentParam` (both signed axis parameters from the pivot): the
    /// ratio `currentParam / startParam`, so grabbing the handle at its tip and
    /// dragging outward grows the object proportionally. `nil` when the start
    /// parameter is (numerically) at the pivot, where the ratio is unstable and
    /// the caller keeps the last value.
    public static func factor(fromParam startParam: Double, toParam currentParam: Double) -> Double? {
        guard abs(startParam) > 1e-6 else { return nil }
        return currentParam / startParam
    }

    private static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return l > 1e-12 ? v / l : v
    }
}
