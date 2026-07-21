import Foundation

/// Proportional ("soft-selection") falloff for live vertex editing
/// (specs/mesh-editing.md §Live vertex edit). Pure kernel math: given a mesh,
/// a seed vertex set, a radius, and a curve, it returns a per-vertex weight in
/// `[0, 1]` that the interaction layer multiplies into a drag delta so a whole
/// region deforms smoothly around the grabbed point.
///
/// Distance is *geodesic* — accumulated along mesh edges via Dijkstra — not raw
/// Euclidean, so falloff follows the surface and does not bleed across
/// unconnected shells or folds that happen to be spatially close.
public enum ProportionalFalloff {

    /// Falloff curves. `t` is normalized distance `d / radius` in `[0, 1]`.
    public enum Curve: Sendable, Equatable, CaseIterable {
        /// Full weight inside the radius, zero outside (hard sphere).
        case constant
        /// `1 - t`.
        case linear
        /// Smoothstep — zero-slope at both ends (the pleasant default).
        case smooth
        /// `sqrt(1 - t²)` — bulges toward full weight near the seed.
        case sphere

        /// Weight for a normalized distance; clamps `t` into `[0, 1]`.
        public func weight(_ t: Double) -> Double {
            let x = min(max(t, 0), 1)
            switch self {
            case .constant: return 1
            case .linear:   return 1 - x
            case .smooth:   let s = 1 - x; return s * s * (3 - 2 * s)
            case .sphere:   return (1 - x * x).squareRoot()
            }
        }
    }

    /// Per-vertex falloff weights out to `radius` from the nearest seed vertex.
    ///
    /// - Seeds always receive weight `1`.
    /// - Vertices beyond `radius` (or unreachable across the edge graph) are
    ///   omitted from the result (implicit weight `0`), keeping the map — and
    ///   therefore the downstream partial GPU write — proportional to the
    ///   affected set, not the mesh size.
    /// - `radius <= 0` yields just the seeds at weight `1` (rigid grab).
    ///
    /// Deterministic: the priority frontier breaks ties by `VertexID`, so the
    /// same inputs always produce the same map (golden-test friendly).
    public static func weights(in mesh: HalfEdgeMesh,
                               seeds: Set<VertexID>,
                               radius: Double,
                               curve: Curve = .smooth) -> [VertexID: Double] {
        var result: [VertexID: Double] = [:]
        for s in seeds where mesh.positions[s] != nil { result[s] = 1 }
        guard radius > 0, !result.isEmpty else { return result }

        let neighbors = vertexAdjacency(in: mesh)

        // Dijkstra over edge-length weights from the whole seed set at once.
        // `best` holds the shortest known geodesic distance to each vertex.
        var best: [VertexID: Double] = [:]
        for s in result.keys { best[s] = 0 }
        // Deterministic frontier: (distance, vertex) sorted; small meshes and
        // bounded radius keep this cheap. Ties break on VertexID.
        var frontier: [(d: Double, v: VertexID)] = result.keys.map { (0, $0) }

        while !frontier.isEmpty {
            frontier.sort { $0.d != $1.d ? $0.d < $1.d : $0.v < $1.v }
            let (d, u) = frontier.removeFirst()
            // Stale entry (a shorter path was already finalized). Every frontier
            // entry is enqueued alongside its `best` value, so `best[u]` exists.
            if d > best[u]! { continue }
            // Every vertex reachable here comes from a face loop (adjacency) or
            // a filtered seed, so it is guaranteed present in `positions`.
            let pu = mesh.positions[u]!
            for w in neighbors[u] ?? [] {
                let nd = d + simd_length(mesh.positions[w]! - pu)
                if nd <= radius && nd < (best[w] ?? .infinity) {
                    best[w] = nd
                    frontier.append((nd, w))
                }
            }
        }

        for (v, d) in best {
            result[v] = curve.weight(d / radius)
        }
        return result
    }

    /// Undirected vertex→vertex adjacency derived from face loops. Built once
    /// per drag by the session and reused across every drag frame.
    public static func vertexAdjacency(in mesh: HalfEdgeMesh) -> [VertexID: Set<VertexID>] {
        var adj: [VertexID: Set<VertexID>] = [:]
        for f in mesh.faceOrder {
            guard let loop = mesh.faceLoops[f] else { continue }
            let n = loop.count
            for i in 0..<n {
                let a = loop[i], b = loop[(i + 1) % n]
                adj[a, default: []].insert(b)
                adj[b, default: []].insert(a)
            }
        }
        return adj
    }
}
