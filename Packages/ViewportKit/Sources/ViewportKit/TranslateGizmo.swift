import Foundation

/// The object-mode move gizmo: three world-aligned arrow handles (X/Y/Z) at
/// the selected prim's world-space pivot — the standard DCC translate gizmo
/// (Blender / Maya / Unity). Dragging an arrow moves the selection along that
/// axis only.
///
/// Pure data + pure math here (same idiom as `ExtrudeGizmo`); the RealityKit
/// layer draws the arrows and forwards drag phases up to the document.
public enum GizmoAxis: Int, CaseIterable, Sendable {
    case x, y, z

    /// Unit world-space direction of the axis.
    public var direction: SIMD3<Double> {
        switch self {
        case .x: SIMD3(1, 0, 0)
        case .y: SIMD3(0, 1, 0)
        case .z: SIMD3(0, 0, 1)
        }
    }
}

/// Where to draw the move gizmo. `origin` is the selection's pivot in world
/// space; `revision` bumps with the document so the viewport re-lays-out in
/// lockstep with edits (including the drag's own live updates — the gizmo
/// follows the object it moves).
public struct TranslateGizmoDescriptor: Equatable, Sendable {
    public var origin: SIMD3<Double>
    public var revision: Int

    public init(origin: SIMD3<Double>, revision: Int = 0) {
        self.origin = origin
        self.revision = revision
    }
}

/// Drag lifecycle reported by the viewport while the user drags an arrow.
/// `changed` carries the signed world-space distance along the grabbed axis
/// since `began`.
public enum TranslateGizmoDragPhase: Equatable, Sendable {
    case began(GizmoAxis)
    case changed(GizmoAxis, Double)
    case ended
}

/// Hit-testing for the three-arrow gizmo; drag math is shared with
/// `ExtrudeGizmoMath` (`axisParameter` / `handleLength`).
public enum TranslateGizmoMath {

    /// The axis whose arrow a world-space `ray` grabs, or `nil` when the ray
    /// misses all three. Each arrow is the segment `[origin, origin + axis·length]`
    /// with the same fat grab capsule as the extrude handle; when the ray is
    /// within reach of more than one arrow (near the shared origin), the
    /// closest wins.
    public static func hitAxis(ray: CameraRay.Ray, origin: SIMD3<Double>,
                               length: Double) -> GizmoAxis? {
        guard length > 0 else { return nil }
        let grabRadius = length * ExtrudeGizmoMath.grabRadiusFraction
        var best: (axis: GizmoAxis, distance: Double)?
        for axis in GizmoAxis.allCases {
            let d = ExtrudeGizmoMath.raySegmentDistance(
                ray: ray, a: origin, b: origin + axis.direction * length)
            guard d <= grabRadius else { continue }
            if best == nil || d < best!.distance { best = (axis, d) }
        }
        return best?.axis
    }
}
