import Foundation

/// CPU-side, GPU-ready buffers for the live vertex edit mode, kept as a pure
/// value type so all the arithmetic — shared-vertex layout, fan triangulation,
/// partial position writes, and affected-normal recomputation — is unit-testable
/// with no RealityKit or GPU present. `LiveMeshRenderer` owns one of these and
/// mirrors its `positions`/`normals` into a `LowLevelMesh` on macOS 15+.
///
/// Unlike `MeshFlattener` (which duplicates a vertex per face for flat shading),
/// this keeps **shared vertices** with a smooth per-vertex normal buffer. That
/// is what makes a drag cheap: moving one prim vertex rewrites one slot plus its
/// 1-ring's normals, instead of every face-corner copy of it. Face legibility in
/// edit mode comes from the point/edge overlay, not from flat shading.
public struct LiveMeshBuffers: Equatable {

    /// Shared-vertex positions, indexed by prim vertex index (identity mapping —
    /// the prim's vertex index *is* the buffer slot).
    public private(set) var positions: [SIMD3<Float>]
    /// Smooth per-vertex normals, parallel to `positions`.
    public private(set) var normals: [SIMD3<Float>]
    /// Triangle index buffer (fan-triangulated face loops), written once and
    /// stable for the whole edit session — topology does not change under a drag.
    public let triangleIndices: [UInt32]
    /// Vertex → the faces incident to it, for 1-ring normal recomputation.
    private let vertexFaces: [[Int]]
    /// The face loops, retained for normal recomputation.
    private let faceLoops: [[Int]]

    public init(positions: [SIMD3<Float>], faceLoops: [[Int]]) {
        self.positions = positions
        self.faceLoops = faceLoops

        var indices: [UInt32] = []
        var incident = [[Int]](repeating: [], count: positions.count)
        for (f, loop) in faceLoops.enumerated() {
            guard loop.count >= 3, loop.allSatisfy({ positions.indices.contains($0) }) else { continue }
            for v in loop where !incident[v].contains(f) { incident[v].append(f) }
            let base = loop
            for i in 1..<(base.count - 1) {
                indices.append(UInt32(base[0]))
                indices.append(UInt32(base[i]))
                indices.append(UInt32(base[i + 1]))
            }
        }
        self.triangleIndices = indices
        self.vertexFaces = incident
        self.normals = Self.computeNormals(positions: positions, faceLoops: faceLoops,
                                           vertexFaces: incident, only: nil)
    }

    /// Apply absolute new positions for a subset of vertices and recompute only
    /// the normals of the affected vertices and their 1-ring (the faces touching
    /// a moved vertex change orientation; their other corners' normals shift too).
    /// Cost scales with the moved set, not the mesh size — the core of the
    /// sub-16ms drag-frame budget.
    public mutating func applyPositionChanges(_ changes: [Int: SIMD3<Float>]) {
        guard !changes.isEmpty else { return }
        var affected = Set(changes.keys)
        for (v, p) in changes where positions.indices.contains(v) {
            positions[v] = p
        }
        // A moved vertex changes every incident face's plane, which in turn
        // shifts the normals of *all* corners of those faces — collect them.
        for v in changes.keys {
            guard vertexFaces.indices.contains(v) else { continue }
            for f in vertexFaces[v] {
                for corner in faceLoops[f] { affected.insert(corner) }
            }
        }
        let recomputed = Self.computeNormals(positions: positions, faceLoops: faceLoops,
                                             vertexFaces: vertexFaces, only: affected)
        for v in affected where normals.indices.contains(v) {
            normals[v] = recomputed[v]
        }
    }

    /// Area-weighted smooth normals. When `only` is non-nil, only those vertices
    /// are computed (the rest of the returned array is zero and the caller copies
    /// just the affected slots).
    static func computeNormals(positions: [SIMD3<Float>], faceLoops: [[Int]],
                               vertexFaces: [[Int]], only: Set<Int>?) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        let targets = only ?? Set(positions.indices)
        for v in targets {
            guard vertexFaces.indices.contains(v) else { continue }
            var n = SIMD3<Float>()
            for f in vertexFaces[v] {
                n += faceNormalArea(faceLoops[f], positions: positions)
            }
            let len = (n * n).sum().squareRoot()
            normals[v] = len > 1e-12 ? n / len : SIMD3(0, 1, 0)
        }
        return normals
    }

    /// Area-weighted face normal (Newell) — zero for degenerate faces.
    static func faceNormalArea(_ loop: [Int], positions: [SIMD3<Float>]) -> SIMD3<Float> {
        var n = SIMD3<Float>()
        guard loop.count >= 3 else { return n }
        for i in loop.indices {
            let p = positions[loop[i]], q = positions[loop[(i + 1) % loop.count]]
            n += SIMD3((p.y - q.y) * (p.z + q.z),
                       (p.z - q.z) * (p.x + q.x),
                       (p.x - q.x) * (p.y + q.y))
        }
        return n * 0.5
    }
}

/// Overlay level-of-detail: at the million-vertex scale you cannot legibly draw
/// every vertex dot, so the overlay draws at most `cap` points, always keeping
/// selected/hovered vertices, and decimating the rest deterministically.
///
/// Deterministic stride sampling (not random) so the drawn set is stable frame
/// to frame — no shimmering as the camera settles. Recomputed only on
/// camera-settle, not per frame.
public enum OverlayLOD {

    /// Choose which prim vertex indices to draw as overlay dots.
    /// - `visible`: candidate indices (already screen/frustum-culled by the caller).
    /// - `pinned`: vertices that must always draw (selected + hovered).
    /// - `cap`: hard maximum drawn dots.
    public static func sample(visible: [Int], pinned: Set<Int>, cap: Int) -> Set<Int> {
        guard cap > 0 else { return pinned }
        var chosen = pinned
        if visible.count <= cap {
            chosen.formUnion(visible)
            return chosen
        }
        // Reserve room for the pinned set; stride-sample the remainder.
        let budget = Swift.max(0, cap - pinned.count)
        guard budget > 0 else { return pinned }
        let candidates = visible.filter { !pinned.contains($0) }
        guard !candidates.isEmpty else { return chosen }
        // Stride so the sample spreads across the whole candidate list.
        let stride = Swift.max(1, candidates.count / budget)
        var i = 0
        while i < candidates.count && chosen.count < cap {
            chosen.insert(candidates[i])
            i += stride
        }
        return chosen
    }
}
