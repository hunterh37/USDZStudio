import Foundation

/// One joint's influence on a vertex.
public struct Influence: Sendable, Equatable, Codable {
    public var joint: Int
    public var weight: Double
    public init(joint: Int, weight: Double) { self.joint = joint; self.weight = weight }
}

/// A skin weight table: per-vertex joint influences.
///
/// Value type. All operations are pure (return a new binding). Mirrors UsdSkel's
/// `primvars:skel:jointIndices` / `jointWeights` (flattened, constant `elementSize`).
public struct SkinBinding: Sendable, Equatable, Codable {
    public private(set) var perVertex: [[Influence]]

    public init(perVertex: [[Influence]]) {
        self.perVertex = perVertex
    }

    public var vertexCount: Int { perVertex.count }

    /// The sum of weights for a vertex (should be ~1 after `normalized`).
    public func weightSum(_ vertex: Int) -> Double {
        perVertex[vertex].reduce(0) { $0 + $1.weight }
    }

    /// Per-vertex weights renormalized to sum to 1. A vertex whose weights sum to ~0 is left
    /// unchanged (there is no meaningful direction to normalize toward).
    public func normalized() -> SkinBinding {
        SkinBinding(perVertex: perVertex.map { influences in
            let sum = influences.reduce(0) { $0 + $1.weight }
            guard sum > 1e-12 else { return influences }
            return influences.map { Influence(joint: $0.joint, weight: $0.weight / sum) }
        })
    }

    /// Drop influences with weight below `threshold`.
    public func pruned(threshold: Double) -> SkinBinding {
        SkinBinding(perVertex: perVertex.map { $0.filter { $0.weight >= threshold } })
    }

    /// Keep at most `maxInfluences` per vertex, retaining the highest weights.
    /// Ties break by lower joint index for determinism.
    public func clamped(maxInfluences: Int) -> SkinBinding {
        SkinBinding(perVertex: perVertex.map { influences in
            let sorted = influences.sorted {
                $0.weight != $1.weight ? $0.weight > $1.weight : $0.joint < $1.joint
            }
            return Array(sorted.prefix(max(0, maxInfluences)))
        })
    }

    /// The maximum number of influences on any vertex.
    public var maxInfluenceCount: Int {
        perVertex.map { $0.count }.max() ?? 0
    }

    /// Remap influence joints through `jointRemap` (e.g. a left↔right symmetry map). Influences
    /// whose joint is absent from the map are kept as-is. Used to author mirrored weights.
    public func remappingJoints(_ jointRemap: [Int: Int]) -> SkinBinding {
        SkinBinding(perVertex: perVertex.map { influences in
            influences.map { Influence(joint: jointRemap[$0.joint] ?? $0.joint, weight: $0.weight) }
        })
    }

    /// Export-profile clamp+prune+normalize in the canonical order (prune tiny, clamp to cap,
    /// renormalize so the surviving weights still sum to 1).
    public func conformed(maxInfluences: Int, pruneThreshold: Double = 1e-4) -> SkinBinding {
        pruned(threshold: pruneThreshold).clamped(maxInfluences: maxInfluences).normalized()
    }

    // MARK: UsdSkel flat form

    /// Flatten to `(jointIndices, jointWeights)` with a constant `influencesPerVertex`
    /// (`elementSize`). Vertices with fewer influences are zero-padded; more are truncated.
    public func flattened(influencesPerVertex n: Int) -> (indices: [Int], weights: [Double]) {
        var indices: [Int] = []
        var weights: [Double] = []
        indices.reserveCapacity(vertexCount * n)
        weights.reserveCapacity(vertexCount * n)
        for influences in perVertex {
            for k in 0..<n {
                if k < influences.count {
                    indices.append(influences[k].joint)
                    weights.append(influences[k].weight)
                } else {
                    indices.append(0)
                    weights.append(0)
                }
            }
        }
        return (indices, weights)
    }

    /// Rebuild from flattened UsdSkel arrays. Returns `nil` if the arrays are malformed
    /// (mismatched lengths, or not a multiple of `influencesPerVertex`).
    public static func fromFlattened(indices: [Int], weights: [Double],
                                     influencesPerVertex n: Int) -> SkinBinding? {
        guard n > 0, indices.count == weights.count, indices.count % n == 0 else { return nil }
        var perVertex: [[Influence]] = []
        var i = 0
        while i < indices.count {
            var v: [Influence] = []
            for k in 0..<n { v.append(Influence(joint: indices[i + k], weight: weights[i + k])) }
            perVertex.append(v)
            i += n
        }
        return SkinBinding(perVertex: perVertex)
    }
}
