import Foundation
import MeshKit

/// The lattice (FFD) cage gizmo: an `l×m×n` grid of draggable control-point
/// handles plus the cage wireframe drawn around a selected mesh
/// (specs/mesh-editing.md §Lattice deformer; research/topics/lattice-deformer).
///
/// Same idiom as the transform gizmos — pure data (`Descriptor`) + pure math
/// (`LatticeCageGizmoMath`) here; the RealityKit layer draws the handle spheres
/// and wire segments and forwards drag phases up to the document, which composes
/// one coalesced undoable "Lattice Deform". Control points live in world space,
/// so a handle position *is* its world position (no separate projection needed
/// for drawing — only for hit-testing).
public struct LatticeCageGizmoDescriptor: Equatable, Sendable {
    /// Control points in world space, row-major (`i + l·(j + m·k)`).
    public var controlPoints: [SIMD3<Double>]
    /// Grid resolution — drives the wireframe edge set and handle layout.
    public var resolution: LatticeCage.Resolution
    /// Currently selected handle indices (highlighted; the drag target set).
    public var selected: Set<Int>
    /// Bumped with the document so the viewport re-lays-out in lockstep.
    public var revision: Int

    public init(controlPoints: [SIMD3<Double>],
                resolution: LatticeCage.Resolution,
                selected: Set<Int> = [],
                revision: Int = 0) {
        self.controlPoints = controlPoints
        self.resolution = resolution
        self.selected = selected
        self.revision = revision
    }
}

/// Drag lifecycle reported by the viewport. `changed` carries the world-space
/// translation of the grabbed handle relative to the drag start; the document
/// applies it to every selected control point and re-bakes the deform.
public enum LatticeCageGizmoDragPhase: Equatable, Sendable {
    case began(handle: Int)
    case changed(handle: Int, worldDelta: SIMD3<Double>)
    case ended
}

/// Hit-testing, wireframe topology, and free-drag math for the cage gizmo.
public enum LatticeCageGizmoMath {

    /// Control-point handle radius as a fraction of the shared handle length.
    public static let handleRadiusFraction = 0.16

    /// The unique undirected edges of the control-point grid, as index pairs —
    /// each node joined to its `+i`, `+j`, `+k` neighbour. This is the cage
    /// wireframe the viewport draws (and it is what makes the box read as a
    /// lattice rather than a point cloud).
    public static func edges(for r: LatticeCage.Resolution) -> [(Int, Int)] {
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { i + r.l * (j + r.m * k) }
        var out: [(Int, Int)] = []
        for k in 0..<r.n {
            for j in 0..<r.m {
                for i in 0..<r.l {
                    let a = index(i, j, k)
                    if i + 1 < r.l { out.append((a, index(i + 1, j, k))) }
                    if j + 1 < r.m { out.append((a, index(i, j + 1, k))) }
                    if k + 1 < r.n { out.append((a, index(i, j, k + 1))) }
                }
            }
        }
        return out
    }

    /// The control-point handle `ray` grabs, or `nil` when it misses them all.
    /// Nearest handle within the fat grab sphere wins (ties break to the lower
    /// index for determinism).
    public static func hitHandle(ray: CameraRay.Ray,
                                 controlPoints: [SIMD3<Double>],
                                 length: Double) -> Int? {
        guard length > 0 else { return nil }
        let grabRadius = length * handleRadiusFraction
        var best: (index: Int, distance: Double)?
        for (i, p) in controlPoints.enumerated() {
            // Degenerate segment == point-to-ray distance, as the uniform scale
            // handle does.
            let d = ExtrudeGizmoMath.raySegmentDistance(ray: ray, a: p, b: p)
            guard d <= grabRadius else { continue }
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// Free-move delta: intersect the start and current rays with the drag plane
    /// (through `point`, facing `normal` — the camera-facing plane through the
    /// grabbed handle) and return `current − start`. `nil` when a ray is parallel
    /// to the plane (the caller then holds the last delta), so a grazing camera
    /// never snaps the handle to infinity.
    public static func planeDelta(startRay: CameraRay.Ray,
                                  currentRay: CameraRay.Ray,
                                  point: SIMD3<Double>,
                                  normal: SIMD3<Double>) -> SIMD3<Double>? {
        guard let p0 = intersect(ray: startRay, point: point, normal: normal),
              let p1 = intersect(ray: currentRay, point: point, normal: normal) else { return nil }
        return p1 - p0
    }

    /// Ray/plane intersection; `nil` when parallel.
    static func intersect(ray: CameraRay.Ray, point: SIMD3<Double>,
                          normal: SIMD3<Double>) -> SIMD3<Double>? {
        let denom = dot(normal, ray.direction)
        guard abs(denom) > 1e-9 else { return nil }
        let t = dot(normal, point - ray.origin) / denom
        return ray.origin + ray.direction * t
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
