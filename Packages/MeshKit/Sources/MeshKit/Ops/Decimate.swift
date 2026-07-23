import Foundation

// MARK: - Quadric error metric

/// Symmetric 4×4 quadric `Q` (Garland–Heckbert), stored as its 10 unique
/// upper-triangular entries. `error(v) = [v 1]ᵀ Q [v 1]` is the squared sum of
/// distances from `v` to the planes accumulated into `Q`.
struct Quadric: Equatable {
    // Q = [ q11 q12 q13 q14
    //       q12 q22 q23 q24
    //       q13 q23 q33 q34
    //       q14 q24 q34 q44 ]
    var q11 = 0.0, q12 = 0.0, q13 = 0.0, q14 = 0.0
    var q22 = 0.0, q23 = 0.0, q24 = 0.0
    var q33 = 0.0, q34 = 0.0
    var q44 = 0.0

    static let zero = Quadric()

    /// Quadric of the plane `n·x + d = 0` (with `n` unit-length).
    static func plane(_ n: SIMD3<Double>, _ d: Double) -> Quadric {
        let (a, b, c) = (n.x, n.y, n.z)
        return Quadric(
            q11: a * a, q12: a * b, q13: a * c, q14: a * d,
            q22: b * b, q23: b * c, q24: b * d,
            q33: c * c, q34: c * d,
            q44: d * d)
    }

    static func + (l: Quadric, r: Quadric) -> Quadric {
        Quadric(
            q11: l.q11 + r.q11, q12: l.q12 + r.q12, q13: l.q13 + r.q13, q14: l.q14 + r.q14,
            q22: l.q22 + r.q22, q23: l.q23 + r.q23, q24: l.q24 + r.q24,
            q33: l.q33 + r.q33, q34: l.q34 + r.q34,
            q44: l.q44 + r.q44)
    }

    static func * (q: Quadric, s: Double) -> Quadric {
        Quadric(
            q11: q.q11 * s, q12: q.q12 * s, q13: q.q13 * s, q14: q.q14 * s,
            q22: q.q22 * s, q23: q.q23 * s, q24: q.q24 * s,
            q33: q.q33 * s, q34: q.q34 * s,
            q44: q.q44 * s)
    }

    /// `vᵀ Q v` — the squared planar error at `v`. Clamped at 0 so accumulated
    /// floating-point noise can never present as a spurious negative cost.
    func error(_ v: SIMD3<Double>) -> Double {
        let (x, y, z) = (v.x, v.y, v.z)
        let e = q11 * x * x + 2 * q12 * x * y + 2 * q13 * x * z + 2 * q14 * x
            + q22 * y * y + 2 * q23 * y * z + 2 * q24 * y
            + q33 * z * z + 2 * q34 * z
            + q44
        return max(e, 0)
    }

    /// Minimiser of `error(·)` — solve the 3×3 top-left block against `-[q14 q24 q34]`.
    /// Returns `nil` when the block is (near-)singular (flat/edge configuration),
    /// leaving the caller to fall back to the endpoint/midpoint candidates.
    func optimalPosition() -> SIMD3<Double>? {
        // Cofactors of the symmetric 3×3 [q11 q12 q13; q12 q22 q23; q13 q23 q33].
        let c00 = q22 * q33 - q23 * q23
        let c01 = q13 * q23 - q12 * q33
        let c02 = q12 * q23 - q13 * q22
        let det = q11 * c00 + q12 * c01 + q13 * c02
        guard abs(det) > 1e-12 else { return nil }
        let c11 = q11 * q33 - q13 * q13
        let c12 = q12 * q13 - q11 * q23
        let c22 = q11 * q22 - q12 * q12
        let inv = 1.0 / det
        let bx = -q14, by = -q24, bz = -q34
        return SIMD3(
            (c00 * bx + c01 * by + c02 * bz) * inv,
            (c01 * bx + c11 * by + c12 * bz) * inv,
            (c02 * bx + c12 * by + c22 * bz) * inv)
    }
}

// MARK: - Decimate op

/// Quadric-error-metric (Garland–Heckbert) edge-collapse decimation.
///
/// The mesh is fan-triangulated, then edges are collapsed cheapest-error-first
/// until a target triangle budget is met. Boundary and UV-seam vertices are
/// *pinned* (frozen in place and never removed), which preserves the silhouette
/// and texture layout exactly while the interior simplifies. Every collapse is
/// guarded by the manifold link condition and a normal-flip test, so the result
/// always passes the full invariant suite.
///
/// Output is a triangle mesh (standard for decimation / LOD authoring). Subsets
/// are carried through by origin face; per-vertex UVs are re-emitted when the
/// input carried them.
public enum Decimate: MeshOp {
    public static let name = "Decimate"

    public struct Params: Sendable {
        /// What to reduce toward.
        public enum Target: Sendable, Equatable {
            /// Fraction of the triangulated triangle count to *keep*, in (0, 1].
            case ratio(Double)
            /// Absolute triangle budget (clamped to ≥ 1).
            case triangleCount(Int)
        }

        public var target: Target
        /// Reject any collapse whose QEM cost exceeds this cap (default: no cap).
        public var maxError: Double
        /// Freeze boundary-loop vertices (default true).
        public var preserveBoundary: Bool
        /// Freeze UV-discontinuity (seam) vertices when the mesh carries UVs
        /// (default true).
        public var preserveUVSeams: Bool

        public init(target: Target,
                    maxError: Double = .infinity,
                    preserveBoundary: Bool = true,
                    preserveUVSeams: Bool = true) {
            self.target = target
            self.maxError = maxError
            self.preserveBoundary = preserveBoundary
            self.preserveUVSeams = preserveUVSeams
        }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard case .faces(let faces) = selection, !faces.isEmpty else {
            throw MeshOpError.emptySelection
        }
        guard faces == Set(mesh.faceOrder) else {
            throw MeshOpError.preconditionFailed("decimate operates on the whole mesh; select all faces")
        }
        // A decimator can only reason about a clean manifold input.
        if let v = MeshInvariants.violations(in: mesh).first {
            throw MeshOpError.nonManifoldRegion(v.description)
        }

        var state = try QEMState(mesh: mesh, params: params)

        let targetTris: Int
        switch params.target {
        case .ratio(let r):
            guard r > 0, r <= 1 else {
                throw MeshOpError.preconditionFailed("keep-ratio must be in (0, 1]")
            }
            targetTris = max(1, Int((Double(state.liveTriangleCount) * r).rounded()))
        case .triangleCount(let n):
            targetTris = max(1, n)
        }
        guard params.maxError >= 0 else {
            throw MeshOpError.preconditionFailed("maxError must be ≥ 0")
        }

        state.paramsMaxError = params.maxError
        state.run(targetTriangles: targetTris)

        let out = state.buildMesh(from: mesh)
        let delta = TopologyDelta(vertices: out.vertexCount - mesh.vertexCount,
                                  edges: out.edgeCount - mesh.edgeCount,
                                  faces: out.faceCount - mesh.faceCount)
        // Decimation's delta is data-dependent (measured, not predicted); verify
        // still enforces the full invariant suite on the result.
        try OpSupport.verify(before: mesh, after: out, predicted: delta)
        return MeshOpResult(mesh: out, resultSelection: .faces(Set(out.faceOrder)), delta: delta)
    }
}

// MARK: - Internal QEM engine

/// Mutable triangle-soup working set for the collapse loop. Kept internal so the
/// op stays a pure function; every field is reconstructed per call.
struct QEMState {
    // Vertex arrays, indexed by internal id (0 ..< count).
    var pos: [SIMD3<Double>]
    var alive: [Bool]
    var pinned: [Bool]
    var uv: [SIMD2<Double>?]
    var quad: [Quadric]
    var vertTris: [Set<Int>]          // vertex → incident live triangles

    // Triangles.
    var tri: [(a: Int, b: Int, c: Int)]
    var triAlive: [Bool]
    var triOriginFace: [FaceID]

    let hasUV: Bool
    var liveTriangleCount: Int

    /// Undirected internal edge, `a < b`.
    struct IEdge: Hashable { let a: Int, b: Int
        init(_ x: Int, _ y: Int) { if x < y { a = x; b = y } else { a = y; b = x } }
    }

    var cost: [IEdge: Double] = [:]     // current best-known cost per live edge

    init(mesh: HalfEdgeMesh, params: Decimate.Params) throws {
        let verts = mesh.vertexOrder
        var index: [VertexID: Int] = [:]
        index.reserveCapacity(verts.count)
        pos = []; pos.reserveCapacity(verts.count)
        for (i, v) in verts.enumerated() {
            index[v] = i
            pos.append(mesh.positions[v]!)
        }
        alive = Array(repeating: true, count: verts.count)
        pinned = Array(repeating: false, count: verts.count)
        uv = Array(repeating: nil, count: verts.count)
        quad = Array(repeating: .zero, count: verts.count)
        vertTris = Array(repeating: [], count: verts.count)
        tri = []; triAlive = []; triOriginFace = []
        liveTriangleCount = 0

        // Per-vertex UV consistency: a vertex whose incident corners disagree on
        // UV is a seam vertex (pinned when preservation is on).
        let uvChannel = mesh.faceCornerUVs
        hasUV = !uvChannel.isEmpty
        var seam = Array(repeating: false, count: verts.count)

        // Fan-triangulate every face; accumulate plane quadrics.
        for f in mesh.faceOrder {
            let loop = mesh.faceLoops[f]!
            let corners = uvChannel[f]
            for (k, vid) in loop.enumerated() {
                let i = index[vid]!
                if let corners {
                    let cornerUV = corners[k]
                    if let existing = uv[i] {
                        if simd_length2(existing - cornerUV) > 1e-18 { seam[i] = true }
                    } else {
                        uv[i] = cornerUV
                    }
                }
            }
            // Triangle fan around loop[0].
            let i0 = index[loop[0]]!
            for k in 1..<(loop.count - 1) {
                let i1 = index[loop[k]]!, i2 = index[loop[k + 1]]!
                let t = tri.count
                tri.append((i0, i1, i2))
                triAlive.append(true)
                triOriginFace.append(f)
                vertTris[i0].insert(t); vertTris[i1].insert(t); vertTris[i2].insert(t)
                let n = triNormalRaw(i0, i1, i2)
                let len = simd_length(n)
                if len > 0 {
                    let unit = n / len
                    let d = -simd_dot(unit, pos[i0])
                    let qp = Quadric.plane(unit, d)
                    quad[i0] = quad[i0] + qp; quad[i1] = quad[i1] + qp; quad[i2] = quad[i2] + qp
                }
            }
        }
        liveTriangleCount = tri.count

        // Boundary detection on the triangulated mesh: an edge in exactly one
        // live triangle bounds the surface. Pin its endpoints and reinforce
        // their quadrics with a plane perpendicular to the boundary edge so the
        // (rare) neighbouring collapses cannot pull the silhouette inward.
        var edgeUses: [IEdge: [Int]] = [:]
        for t in tri.indices {
            let (a, b, c) = tri[t]
            edgeUses[IEdge(a, b), default: []].append(t)
            edgeUses[IEdge(b, c), default: []].append(t)
            edgeUses[IEdge(c, a), default: []].append(t)
        }
        for (e, uses) in edgeUses where uses.count == 1 {
            let t = uses[0]
            let n = triNormalRaw(tri[t].a, tri[t].b, tri[t].c)
            let len = simd_length(n)
            if len > 0 {
                let faceN = n / len
                let edgeDir = pos[e.b] - pos[e.a]
                let edgeLen = simd_length(edgeDir)
                if edgeLen > 0 {
                    // Plane containing the edge and perpendicular to the face.
                    let perp = simd_normalize(simd_cross(edgeDir / edgeLen, faceN))
                    let d = -simd_dot(perp, pos[e.a])
                    let boundaryQ = Quadric.plane(perp, d) * 1_000.0
                    quad[e.a] = quad[e.a] + boundaryQ
                    quad[e.b] = quad[e.b] + boundaryQ
                }
            }
            if params.preserveBoundary { pinned[e.a] = true; pinned[e.b] = true }
        }

        if params.preserveUVSeams && hasUV {
            for i in seam.indices where seam[i] { pinned[i] = true }
        }

        // Seed the edge-cost table.
        for e in edgeUses.keys { cost[e] = collapseCost(e).cost }
    }

    // MARK: Geometry helpers

    func triNormalRaw(_ a: Int, _ b: Int, _ c: Int) -> SIMD3<Double> {
        simd_cross(pos[b] - pos[a], pos[c] - pos[a])
    }

    /// Chosen survivor/target and cost for collapsing edge `e`.
    /// `cost == .infinity` marks a forbidden collapse (both endpoints pinned).
    func collapseCost(_ e: IEdge) -> (cost: Double, survivor: Int, removed: Int, target: SIMD3<Double>) {
        let (u, v) = (e.a, e.b)
        let qbar = quad[u] + quad[v]
        if pinned[u] && pinned[v] {
            return (.infinity, u, v, pos[u])
        }
        if pinned[u] != pinned[v] {
            // Collapse toward the pinned endpoint; it neither moves nor dies.
            let survivor = pinned[u] ? u : v
            let removed = pinned[u] ? v : u
            return (qbar.error(pos[survivor]), survivor, removed, pos[survivor])
        }
        // Neither pinned: choose the lowest-error of the endpoints, the midpoint,
        // and (when the block is non-singular) the analytic optimum.
        var candidates = [pos[u], pos[v], (pos[u] + pos[v]) * 0.5]
        if let opt = qbar.optimalPosition() { candidates.append(opt) }
        let target = candidates.min { qbar.error($0) < qbar.error($1) }!
        return (qbar.error(target), u, v, target)
    }

    // MARK: Collapse loop

    mutating func run(targetTriangles: Int) {
        while liveTriangleCount > targetTriangles {
            guard let (edge, plan) = cheapestValidCollapse() else { break }
            if plan.cost > paramsMaxError { break }
            _ = edge
            collapse(survivor: plan.survivor, removed: plan.removed, target: plan.target)
        }
    }

    // maxError threaded through without widening every signature.
    var paramsMaxError: Double = .infinity

    struct Plan { let cost: Double; let survivor: Int; let removed: Int; let target: SIMD3<Double> }

    /// Scan the current edge table for the cheapest collapse that survives the
    /// link-condition and flip guards. Deterministic: ties break on edge id.
    mutating func cheapestValidCollapse() -> (IEdge, Plan)? {
        var best: (IEdge, Plan)?
        for e in cost.keys.sorted(by: edgeLess) {
            guard alive[e.a], alive[e.b] else { cost.removeValue(forKey: e); continue }
            let c = collapseCost(e)
            if c.cost.isInfinite { continue }
            cost[e] = c.cost
            if let b = best, c.cost >= b.1.cost { continue }
            guard linkConditionOK(e), !collapseFlips(survivor: c.survivor, removed: c.removed, target: c.target)
            else { continue }
            best = (e, Plan(cost: c.cost, survivor: c.survivor, removed: c.removed, target: c.target))
        }
        return best
    }

    func edgeLess(_ l: IEdge, _ r: IEdge) -> Bool { (l.a, l.b) < (r.a, r.b) }

    /// Manifold link condition: the only vertices adjacent to *both* endpoints
    /// must be the third vertices of the triangles on edge (u,v). Otherwise the
    /// collapse would weld two rings into a non-manifold edge.
    func linkConditionOK(_ e: IEdge) -> Bool {
        let shared = vertTris[e.a].intersection(vertTris[e.b])
        var opposites = Set<Int>()
        for t in shared {
            let (a, b, c) = tri[t]
            for x in [a, b, c] where x != e.a && x != e.b { opposites.insert(x) }
        }
        func ring(_ v: Int) -> Set<Int> {
            var s = Set<Int>()
            for t in vertTris[v] {
                let (a, b, c) = tri[t]
                for x in [a, b, c] where x != v { s.insert(x) }
            }
            return s
        }
        let common = ring(e.a).intersection(ring(e.b))
        return common == opposites
    }

    /// A collapse is rejected if any surviving incident triangle would invert
    /// its normal or shrink to zero area at the new survivor position.
    func collapseFlips(survivor: Int, removed: Int, target: SIMD3<Double>) -> Bool {
        for t in vertTris[survivor].union(vertTris[removed]) {
            let (a, b, c) = tri[t]
            // Triangles on the collapsing edge vanish — skip them.
            if (a == survivor || a == removed) && (b == survivor || b == removed) { continue }
            if (b == survivor || b == removed) && (c == survivor || c == removed) { continue }
            if (c == survivor || c == removed) && (a == survivor || a == removed) { continue }
            func moved(_ i: Int) -> SIMD3<Double> { (i == survivor || i == removed) ? target : pos[i] }
            let before = triNormalRaw(a, b, c)
            let pa = moved(a), pb = moved(b), pc = moved(c)
            let after = simd_cross(pb - pa, pc - pa)
            let len = simd_length(after)
            if len <= MeshInvariants.epsilon { return true }        // degenerate
            if simd_dot(before, after) <= 0 { return true }         // flipped
        }
        return false
    }

    mutating func collapse(survivor: Int, removed: Int, target: SIMD3<Double>) {
        pos[survivor] = target
        quad[survivor] = quad[survivor] + quad[removed]
        pinned[survivor] = pinned[survivor] || pinned[removed]

        // Triangles containing both endpoints die; others rewire removed→survivor.
        let touched = vertTris[removed].union(vertTris[survivor])
        var affected = Set<Int>()
        for t in touched {
            var (a, b, c) = tri[t]
            let hasS = a == survivor || b == survivor || c == survivor
            let hasR = a == removed || b == removed || c == removed
            if hasS && hasR {
                triAlive[t] = false
                liveTriangleCount -= 1
                for x in [a, b, c] { vertTris[x].remove(t); affected.insert(x) }
                continue
            }
            if a == removed { a = survivor }; if b == removed { b = survivor }; if c == removed { c = survivor }
            tri[t] = (a, b, c)
            vertTris[survivor].insert(t)
            for x in [a, b, c] { affected.insert(x) }
        }
        alive[removed] = false
        vertTris[removed] = []
        affected.remove(removed)

        // Refresh costs of every edge touching the affected ring.
        for e in Array(cost.keys) where e.a == removed || e.b == removed {
            cost.removeValue(forKey: e)
        }
        for v in affected where alive[v] {
            for w in ring(v) where alive[w] {
                cost[IEdge(v, w)] = collapseCost(IEdge(v, w)).cost
            }
        }
    }

    func ring(_ v: Int) -> Set<Int> {
        var s = Set<Int>()
        for t in vertTris[v] {
            let (a, b, c) = tri[t]
            for x in [a, b, c] where x != v { s.insert(x) }
        }
        return s
    }

    // MARK: Output

    func buildMesh(from original: HalfEdgeMesh) -> HalfEdgeMesh {
        var out = HalfEdgeMesh()
        var newID = [Int: VertexID]()
        for i in pos.indices where alive[i] {
            newID[i] = out.addVertex(pos[i])
        }
        // Map each original subset via origin-face membership.
        let originalSubsets = original.subsets
        var subsetFaces: [String: Set<FaceID>] = [:]
        for name in originalSubsets.keys { subsetFaces[name] = [] }

        for t in tri.indices where triAlive[t] {
            let (a, b, c) = tri[t]
            // Guard against any residual degeneracy (kept impossible by the flip
            // test, asserted here so a bad build fails the invariant check).
            guard a != b, b != c, a != c else { continue }
            let loop = [newID[a]!, newID[b]!, newID[c]!]
            let uvs: [SIMD2<Double>]? = hasUV
                ? [uv[a] ?? .zero, uv[b] ?? .zero, uv[c] ?? .zero]
                : nil
            let f = out.addFace(loop, uvs: uvs)
            let origin = triOriginFace[t]
            for (name, members) in originalSubsets where members.contains(origin) {
                subsetFaces[name]?.insert(f)
            }
        }
        out.setSubsets(subsetFaces.filter { !$0.value.isEmpty })
        return out
    }
}

@inlinable func simd_length2(_ a: SIMD2<Double>) -> Double { (a * a).sum() }
