import Foundation

/// The active object-mode manipulator, switched with the DCC-standard W/E/R
/// idiom (Maya/Unity): **W** translate, **E** rotate, **R** scale. The three
/// transform gizmos share one hit-test/drag-routing seam (`GizmoAxis`,
/// `CameraRay`, the `ExtrudeGizmoMath` axis-parameter math); only the active
/// mode's handles are shown and pickable.
public enum GizmoMode: String, CaseIterable, Sendable {
    case translate, rotate, scale

    /// The keyboard shortcut that selects this mode (Maya/Unity convention).
    public var shortcut: Character {
        switch self {
        case .translate: "w"
        case .rotate: "e"
        case .scale: "r"
        }
    }

    /// The mode a pressed key selects, or `nil` for any other key.
    public static func forShortcut(_ key: Character) -> GizmoMode? {
        let lowered = Character(key.lowercased())
        return allCases.first { $0.shortcut == lowered }
    }
}

/// Which frame the gizmo's axes are drawn in: `world` (axis-aligned, the
/// default) or `local` (aligned to the selection's own rotated basis).
public enum GizmoOrientation: String, CaseIterable, Sendable {
    case world, local
}

/// Where a multi-selection rotate/scale pivots: `median` about the shared
/// centroid of the selection (the default), or `individual` about each prim's
/// own origin.
public enum GizmoPivot: String, CaseIterable, Sendable {
    case median, individual
}

/// An orthonormal basis the rotate/scale gizmos are drawn and manipulated in.
/// `world` is the identity basis; a `local` orientation carries the selection's
/// rotated axes so a ring/handle lines up with the object it edits.
public struct GizmoBasis: Equatable, Sendable {
    public var x: SIMD3<Double>
    public var y: SIMD3<Double>
    public var z: SIMD3<Double>

    public init(x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// The world-aligned identity basis.
    public static let world = GizmoBasis(x: SIMD3(1, 0, 0),
                                         y: SIMD3(0, 1, 0),
                                         z: SIMD3(0, 0, 1))

    /// The unit direction of the given axis in this basis.
    public func direction(_ axis: GizmoAxis) -> SIMD3<Double> {
        switch axis {
        case .x: x
        case .y: y
        case .z: z
        }
    }
}
