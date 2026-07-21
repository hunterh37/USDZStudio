import Foundation

// MARK: - Stable component identifiers

public struct VertexID: Hashable, Comparable, Sendable, Codable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (lhs: VertexID, rhs: VertexID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct FaceID: Hashable, Comparable, Sendable, Codable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (lhs: FaceID, rhs: FaceID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An undirected edge, normalized so `a < b`. Edges are derived from face
/// loops rather than stored; the key is stable as long as its endpoint
/// vertices survive.
public struct EdgeKey: Hashable, Sendable, Codable {
    public let a: VertexID
    public let b: VertexID
    public init(_ x: VertexID, _ y: VertexID) {
        if x < y { a = x; b = y } else { a = y; b = x }
    }
    public func contains(_ v: VertexID) -> Bool { v == a || v == b }
}

extension EdgeKey: Comparable {
    /// Deterministic ordering for stable op iteration and the HUD edge-picker.
    public static func < (l: EdgeKey, r: EdgeKey) -> Bool { (l.a, l.b) < (r.a, r.b) }
}

// MARK: - Selection

public enum ComponentSelection: Sendable, Equatable {
    case vertices(Set<VertexID>)
    case edges(Set<EdgeKey>)
    case faces(Set<FaceID>)

    public var isEmpty: Bool {
        switch self {
        case .vertices(let s): return s.isEmpty
        case .edges(let s): return s.isEmpty
        case .faces(let s): return s.isEmpty
        }
    }
}

// MARK: - Mesh

/// Value-semantic polygon mesh with stable component IDs (specs/mesh-editing.md).
///
/// Storage is face-loop based ("polygon soup with shared vertices"); half-edge
/// adjacency (edge→faces, vertex→faces, boundary loops) is derived on demand.
/// This keeps the struct trivially CoW-snapshotable for undo while still
/// answering every adjacency query the v1 op set needs.
///
/// Ordering: `vertexOrder` / `faceOrder` preserve authoring (USD) order so
/// `MeshIO` round-trips untouched meshes bit-faithfully.
public struct HalfEdgeMesh: Equatable, Sendable {

    public private(set) var positions: [VertexID: SIMD3<Double>] = [:]
    /// Counter-clockwise vertex loop per face (≥ 3 vertices, no repeats).
    public private(set) var faceLoops: [FaceID: [VertexID]] = [:]
    /// Optional per-face-corner UVs, parallel to the face loop.
    public private(set) var faceCornerUVs: [FaceID: [SIMD2<Double>]] = [:]
    /// GeomSubset membership: subset name → member faces.
    public private(set) var subsets: [String: Set<FaceID>] = [:]

    public private(set) var vertexOrder: [VertexID] = []
    public private(set) var faceOrder: [FaceID] = []

    private var nextVertexRaw = 0
    private var nextFaceRaw = 0

    public init() {}

    // MARK: Counts

    public var vertexCount: Int { positions.count }
    public var faceCount: Int { faceLoops.count }
    /// Unique undirected edge count. Counts edge keys directly instead of
    /// materialising the full `edgeFaceMap` (which allocates a `[FaceID]`
    /// value array per edge) — this is read once per op via `OpSupport.verify`.
    public var edgeCount: Int {
        var edges = Set<EdgeKey>()
        edges.reserveCapacity(faceLoops.count * 2)
        for f in faceOrder {
            guard let loop = faceLoops[f] else { continue }
            for i in loop.indices {
                edges.insert(EdgeKey(loop[i], loop[(i + 1) % loop.count]))
            }
        }
        return edges.count
    }

    // MARK: Mutation primitives (used by ops; keep order arrays coherent)

    @discardableResult
    public mutating func addVertex(_ position: SIMD3<Double>) -> VertexID {
        let id = VertexID(nextVertexRaw)
        nextVertexRaw += 1
        positions[id] = position
        vertexOrder.append(id)
        return id
    }

    @discardableResult
    public mutating func addFace(_ loop: [VertexID], uvs: [SIMD2<Double>]? = nil) -> FaceID {
        precondition(loop.count >= 3, "face loop must have ≥ 3 vertices")
        let id = FaceID(nextFaceRaw)
        nextFaceRaw += 1
        faceLoops[id] = loop
        faceOrder.append(id)
        if let uvs { faceCornerUVs[id] = uvs }
        return id
    }

    public mutating func removeFace(_ id: FaceID) { removeFaces([id]) }

    /// Batch face removal. Filters `faceOrder` (and each subset) in a single
    /// pass, so deleting k faces is O(faceCount + subsets) rather than the
    /// O(k · faceCount) of calling `removeFace` in a loop.
    public mutating func removeFaces(_ ids: Set<FaceID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            faceLoops.removeValue(forKey: id)
            faceCornerUVs.removeValue(forKey: id)
        }
        faceOrder.removeAll { ids.contains($0) }
        for key in subsets.keys { subsets[key]?.subtract(ids) }
    }

    public mutating func removeVertex(_ id: VertexID) { removeVertices([id]) }

    /// Batch vertex removal — single-pass `vertexOrder` filter (see `removeFaces`).
    public mutating func removeVertices(_ ids: Set<VertexID>) {
        guard !ids.isEmpty else { return }
        for id in ids { positions.removeValue(forKey: id) }
        vertexOrder.removeAll { ids.contains($0) }
    }

    public mutating func setPosition(_ p: SIMD3<Double>, for id: VertexID) {
        precondition(positions[id] != nil, "unknown vertex \(id.rawValue)")
        positions[id] = p
    }

    public mutating func replaceLoop(_ loop: [VertexID], for id: FaceID) {
        precondition(faceLoops[id] != nil, "unknown face \(id.rawValue)")
        faceLoops[id] = loop
        // Loop changed → any per-corner attribute parallelism is broken.
        faceCornerUVs.removeValue(forKey: id)
    }

    public mutating func addFaceToSubset(_ face: FaceID, subset: String) {
        subsets[subset, default: []].insert(face)
    }

    public mutating func setSubsets(_ new: [String: Set<FaceID>]) { subsets = new }

    /// Remove vertices no longer referenced by any face.
    public mutating func pruneIsolatedVertices() {
        var referenced = Set<VertexID>()
        for loop in faceLoops.values { referenced.formUnion(loop) }
        removeVertices(Set(positions.keys.lazy.filter { !referenced.contains($0) }))
    }

    // MARK: Derived adjacency

    /// Undirected edge → adjacent faces (in face-order for determinism).
    public var edgeFaceMap: [EdgeKey: [FaceID]] {
        var map: [EdgeKey: [FaceID]] = [:]
        map.reserveCapacity(faceLoops.count * 2)
        for f in faceOrder {
            guard let loop = faceLoops[f] else { continue }
            for i in loop.indices {
                map[EdgeKey(loop[i], loop[(i + 1) % loop.count]), default: []].append(f)
            }
        }
        return map
    }

    public var vertexFaceMap: [VertexID: [FaceID]] {
        var map: [VertexID: [FaceID]] = [:]
        map.reserveCapacity(positions.count)
        for f in faceOrder {
            for v in faceLoops[f] ?? [] { map[v, default: []].append(f) }
        }
        return map
    }

    /// Edges bounding exactly one face.
    public var boundaryEdges: Set<EdgeKey> {
        Set(edgeFaceMap.filter { $0.value.count == 1 }.keys)
    }

    // MARK: Geometry

    public func faceCentroid(_ id: FaceID) -> SIMD3<Double> {
        let loop = faceLoops[id]!
        var c = SIMD3<Double>()
        for v in loop { c += positions[v]! }
        return c / Double(loop.count)
    }

    /// Area-weighted face normal (Newell's method); zero for degenerate faces.
    public func faceNormalArea(_ id: FaceID) -> SIMD3<Double> {
        let loop = faceLoops[id]!
        var n = SIMD3<Double>()
        for i in loop.indices {
            let p = positions[loop[i]]!, q = positions[loop[(i + 1) % loop.count]]!
            n += SIMD3(
                (p.y - q.y) * (p.z + q.z),
                (p.z - q.z) * (p.x + q.x),
                (p.x - q.x) * (p.y + q.y))
        }
        return n * 0.5
    }

    public func faceArea(_ id: FaceID) -> Double {
        let n = faceNormalArea(id)
        return (n * n).sum().squareRoot()
    }

    /// Signed volume via divergence theorem (valid for closed meshes).
    public var signedVolume: Double {
        var vol = 0.0
        for (f, loop) in faceLoops {
            _ = f
            let p0 = positions[loop[0]]!
            for i in 1..<(loop.count - 1) {
                let p1 = positions[loop[i]]!, p2 = positions[loop[i + 1]]!
                vol += simd_dot(p0, simd_cross(p1, p2)) / 6.0
            }
        }
        return vol
    }

    /// Content hash for undo/round-trip verification (invariant 8).
    public var topologyHash: Int {
        var hasher = Hasher()
        for v in vertexOrder {
            hasher.combine(v)
            let p = positions[v]!
            hasher.combine(p.x); hasher.combine(p.y); hasher.combine(p.z)
        }
        for f in faceOrder {
            hasher.combine(f)
            hasher.combine(faceLoops[f]!)
        }
        return hasher.finalize()
    }
}

@inlinable func simd_dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
@inlinable func simd_cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inlinable func simd_length(_ a: SIMD3<Double>) -> Double { simd_dot(a, a).squareRoot() }
@inlinable func simd_normalize(_ a: SIMD3<Double>) -> SIMD3<Double> {
    let l = simd_length(a); return l > 0 ? a / l : a
}
