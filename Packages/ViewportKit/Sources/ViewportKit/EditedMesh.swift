import Foundation

/// Geometry handed to the viewport while a mesh is being component-edited
/// (Phase 6): the live working mesh replaces the file-loaded model for that
/// prim, so edits are visible immediately. Pure data — the RealityKit layer
/// consumes the flattened output below.
public struct EditedMeshData: Equatable, Sendable {
    /// Entity lookup key: the prim's name as RealityKit names its entity.
    public var primName: String
    /// Full prim path ("/Rig/Panel") — disambiguates when two prims share a
    /// name at different depths; empty = fall back to name lookup.
    public var primPath: String
    public var positions: [SIMD3<Float>]
    /// Per-face vertex-index loops (n-gons allowed; fan-triangulated for GPU).
    public var faceLoops: [[Int]]
    /// Indices into `faceLoops` currently selected (highlighted amber).
    public var selectedFaces: Set<Int>
    /// Bumped by the editor on every change so the viewport knows to re-mesh.
    public var revision: Int

    public init(primName: String, primPath: String = "", positions: [SIMD3<Float>], faceLoops: [[Int]],
                selectedFaces: Set<Int> = [], revision: Int = 0) {
        self.primName = primName
        self.primPath = primPath
        self.positions = positions
        self.faceLoops = faceLoops
        self.selectedFaces = selectedFaces
        self.revision = revision
    }
}

/// Flat-shaded GPU buffers from face loops: vertices are duplicated per face
/// so each face gets its own normal — the right look for component editing,
/// where face boundaries must read clearly.
public enum MeshFlattener {

    public struct Buffers: Equatable {
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]
        public var triangleIndices: [UInt32]
    }

    /// Flatten `faces` (defaults to all) into triangle buffers.
    public static func flatten(_ data: EditedMeshData, faces: [Int]? = nil) -> Buffers {
        flatten(positions: data.positions, faceLoops: data.faceLoops, faces: faces)
    }

    /// Flatten raw geometry — shared by the component-edit path and the
    /// scene-graph path, which describe meshes the same way.
    public static func flatten(positions: [SIMD3<Float>], faceLoops: [[Int]],
                               faces: [Int]? = nil) -> Buffers {
        let selected = faces ?? Array(faceLoops.indices)
        var out = Buffers(positions: [], normals: [], triangleIndices: [])
        // Pre-size the output buffers from the known corner budget so this
        // per-revision (drag-time) rebuild doesn't repeatedly reallocate.
        var corners = 0
        for f in selected where faceLoops.indices.contains(f) { corners += faceLoops[f].count }
        out.positions.reserveCapacity(corners)
        out.normals.reserveCapacity(corners)
        out.triangleIndices.reserveCapacity(corners * 3)
        for f in selected {
            guard faceLoops.indices.contains(f) else { continue }
            let loop = faceLoops[f]
            guard loop.count >= 3, loop.allSatisfy({ positions.indices.contains($0) }) else { continue }
            let pts = loop.map { positions[$0] }
            let normal = newellNormal(pts)
            let base = UInt32(out.positions.count)
            out.positions.append(contentsOf: pts)
            for _ in pts { out.normals.append(normal) }
            for i in 1..<(pts.count - 1) {
                out.triangleIndices.append(base)
                out.triangleIndices.append(base + UInt32(i))
                out.triangleIndices.append(base + UInt32(i + 1))
            }
        }
        return out
    }

    static func newellNormal(_ pts: [SIMD3<Float>]) -> SIMD3<Float> {
        var n = SIMD3<Float>()
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            n += SIMD3((p.y - q.y) * (p.z + q.z),
                       (p.z - q.z) * (p.x + q.x),
                       (p.x - q.x) * (p.y + q.y))
        }
        let len = (n * n).sum().squareRoot()
        return len > 1e-12 ? n / len : SIMD3(0, 1, 0)
    }
}

/// A world-space pick ray from a click point, using the same orbit-camera
/// basis the viewport renders with. Pure math, unit-tested.
public enum CameraRay {

    public struct Ray: Equatable {
        public var origin: SIMD3<Double>
        public var direction: SIMD3<Double>
        public init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
            self.origin = origin
            self.direction = direction
        }
    }

    /// `point` in view coordinates with origin at top-left (AppKit's flipped
    /// convention already applied by the caller).
    public static func make(camera: OrbitCamera, viewSize: CGSize, point: CGPoint) -> Ray? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let ndcX = (2 * point.x / viewSize.width) - 1
        let ndcY = 1 - (2 * point.y / viewSize.height)
        let aspect = viewSize.width / viewSize.height
        let halfV = tan(OrbitCamera.verticalFOV / 2)
        let dir = camera.forwardVector
            + camera.rightVector * (ndcX * aspect * halfV)
            + camera.upVector * (ndcY * halfV)
        let len = (dir * dir).sum().squareRoot()
        guard len > 1e-12 else { return nil }
        return Ray(origin: camera.position, direction: dir / len)
    }
}

/// Ray → face hit-testing against the edited mesh (screen picking until the
/// full Metal overlay pass lands). Möller–Trumbore per fan triangle; nearest
/// hit wins.
public enum MeshPicker {

    public struct Hit: Equatable {
        public var faceIndex: Int
        public var distance: Double

        /// Deterministic ordering shared by every picking implementation:
        /// nearest wins; hits within rounding tolerance of each other (a ray
        /// through a shared corner computes t differing by ulps per triangle)
        /// tie-break to the lowest face index.
        static func isBetter(_ t: Double, _ face: Int, than best: Hit?) -> Bool {
            guard let best else { return true }
            let eps = 1e-9 * Swift.max(1, abs(best.distance))
            if t < best.distance - eps { return true }
            if t <= best.distance + eps {
                if face < best.faceIndex { return true }
                if face == best.faceIndex { return t < best.distance }
            }
            return false
        }
    }

    public static func pickFace(ray: CameraRay.Ray, in data: EditedMeshData) -> Hit? {
        var best: Hit?
        for (f, loop) in data.faceLoops.enumerated() {
            guard loop.count >= 3, loop.allSatisfy({ data.positions.indices.contains($0) }) else { continue }
            let pts = loop.map { SIMD3<Double>(data.positions[$0]) }
            for i in 1..<(pts.count - 1) {
                guard let t = intersect(ray: ray, a: pts[0], b: pts[i], c: pts[i + 1]) else { continue }
                if Hit.isBetter(t, f, than: best) { best = Hit(faceIndex: f, distance: t) }
            }
        }
        return best
    }

    /// Möller–Trumbore; returns the ray parameter t for a front- or back-face
    /// hit (editing wants both — you can click the far side of an open shell).
    static func intersect(ray: CameraRay.Ray, a: SIMD3<Double>, b: SIMD3<Double>,
                          c: SIMD3<Double>) -> Double? {
        let e1 = b - a, e2 = c - a
        let p = cross(ray.direction, e2)
        let det = dot(e1, p)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        let s = ray.origin - a
        let u = dot(s, p) * inv
        guard u >= -1e-9, u <= 1 + 1e-9 else { return nil }
        let q = cross(s, e1)
        let v = dot(ray.direction, q) * inv
        guard v >= -1e-9, u + v <= 1 + 1e-9 else { return nil }
        let t = dot(e2, q) * inv
        return t > 1e-9 ? t : nil
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
