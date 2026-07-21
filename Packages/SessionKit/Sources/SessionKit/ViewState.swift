import Foundation
import ViewportKit

/// The orbit-camera pose, stored as plain scalars so it round-trips through
/// `Codable` (``ViewportCameraPose`` wraps a non-`Codable` `SIMD3`). Mirrors the
/// on-disk shape ``CameraBookmark`` already uses, so a malformed `target`
/// degrades to the origin rather than crashing.
public struct CameraState: Equatable, Codable, Sendable {
    public var target: [Double]
    public var distance: Double
    public var azimuth: Double
    public var elevation: Double

    public init(target: [Double], distance: Double, azimuth: Double, elevation: Double) {
        self.target = target
        self.distance = distance
        self.azimuth = azimuth
        self.elevation = elevation
    }

    /// Captures a live viewport pose.
    public init(pose: ViewportCameraPose) {
        self.init(target: [pose.target.x, pose.target.y, pose.target.z],
                  distance: pose.distance, azimuth: pose.azimuth, elevation: pose.elevation)
    }

    /// The stored scalars as a viewport pose. A `target` of the wrong arity
    /// (hand-edited or migrated) degrades to the origin.
    public var pose: ViewportCameraPose {
        let t = target.count == 3
            ? SIMD3<Double>(target[0], target[1], target[2]) : .zero
        return ViewportCameraPose(target: t, distance: distance,
                                  azimuth: azimuth, elevation: elevation)
    }
}

/// The transient, per-document view/UI state that is *not* part of the saved
/// file but should survive a relaunch: what was selected, how the outliner was
/// expanded, which gizmo/panels were active, the camera pose, and the lighting.
///
/// Every field is optional or defaulted and decodes leniently: a session written
/// by an older build (missing a field) or hand-edited into an unknown enum value
/// degrades to a sensible default instead of failing the whole restore. Paths
/// and enum cases are stored as `String`s so `SessionKit` stays decoupled from
/// the concrete `PrimPath`/`GizmoMode` types the EditorUI layer maps back to.
public struct ViewState: Equatable, Codable, Sendable {
    /// Absolute path strings of the selected prims (`PrimPath.description`).
    public var selectionPaths: [String]
    /// The primary selection (anchors the inspector / breadcrumb), if any.
    public var primarySelectionPath: String?
    /// Outliner rows that were collapsed.
    public var collapsedPaths: [String]
    /// Active transform gizmo (`GizmoMode.rawValue`).
    public var gizmoMode: String?
    /// Gizmo orientation basis (`GizmoOrientation.rawValue`).
    public var gizmoOrientation: String?
    /// Multi-select pivot mode (`GizmoPivot.rawValue`).
    public var gizmoPivotMode: String?
    /// Isolate-mode roots (`PrimPath.description`); empty when isolate was off.
    public var isolationRoots: [String]
    /// Panel/sheet visibility, keyed by a stable panel identifier.
    public var panelVisibility: [String: Bool]
    /// Viewport camera pose.
    public var camera: CameraState?
    /// Environment/lighting (reused from ViewportKit, already `Codable`).
    public var environment: EnvironmentSettings?
    /// Playback transport position in seconds.
    public var playbackPosition: Double?

    public init(
        selectionPaths: [String] = [],
        primarySelectionPath: String? = nil,
        collapsedPaths: [String] = [],
        gizmoMode: String? = nil,
        gizmoOrientation: String? = nil,
        gizmoPivotMode: String? = nil,
        isolationRoots: [String] = [],
        panelVisibility: [String: Bool] = [:],
        camera: CameraState? = nil,
        environment: EnvironmentSettings? = nil,
        playbackPosition: Double? = nil
    ) {
        self.selectionPaths = selectionPaths
        self.primarySelectionPath = primarySelectionPath
        self.collapsedPaths = collapsedPaths
        self.gizmoMode = gizmoMode
        self.gizmoOrientation = gizmoOrientation
        self.gizmoPivotMode = gizmoPivotMode
        self.isolationRoots = isolationRoots
        self.panelVisibility = panelVisibility
        self.camera = camera
        self.environment = environment
        self.playbackPosition = playbackPosition
    }

    /// Lenient decode: every field defaults when absent, so a session envelope
    /// written by an earlier build restores what it can and ignores the rest.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectionPaths = try c.decodeIfPresent([String].self, forKey: .selectionPaths) ?? []
        primarySelectionPath = try c.decodeIfPresent(String.self, forKey: .primarySelectionPath)
        collapsedPaths = try c.decodeIfPresent([String].self, forKey: .collapsedPaths) ?? []
        gizmoMode = try c.decodeIfPresent(String.self, forKey: .gizmoMode)
        gizmoOrientation = try c.decodeIfPresent(String.self, forKey: .gizmoOrientation)
        gizmoPivotMode = try c.decodeIfPresent(String.self, forKey: .gizmoPivotMode)
        isolationRoots = try c.decodeIfPresent([String].self, forKey: .isolationRoots) ?? []
        panelVisibility = try c.decodeIfPresent([String: Bool].self, forKey: .panelVisibility) ?? [:]
        camera = try c.decodeIfPresent(CameraState.self, forKey: .camera)
        environment = try c.decodeIfPresent(EnvironmentSettings.self, forKey: .environment)
        playbackPosition = try c.decodeIfPresent(Double.self, forKey: .playbackPosition)
    }
}
