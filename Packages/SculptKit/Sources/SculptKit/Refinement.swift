import Foundation

/// A real geometry-refinement operation applied to a component's mesh during
/// the `formRefinement` pass. Unlike the review-only passes, these author actual
/// topology changes: the AgentMCP executor reads the authored prim back into a
/// `MeshKit.HalfEdgeMesh`, applies the op over the whole mesh, and re-authors
/// the result. SculptKit only carries the declarative intent — it performs no
/// mesh surgery itself, keeping the module a pure leaf.
///
/// v1 exposes `inset` (adds surface definition — a recessed inner ring on every
/// face). The op applies cleanly to a full-face selection, so it is always
/// valid on any authored primitive; more ops can be added behind new cases.
public enum MeshRefinement: Codable, Sendable, Equatable {
    /// Inset every face: each face grows a recessed inner ring. `fraction` is
    /// how far each corner moves toward the face centroid (0 < fraction < 1);
    /// `depth` offsets the inner ring along the face normal (negative = inward).
    case inset(fraction: Double, depth: Double)

    private enum CodingKeys: String, CodingKey { case kind, fraction, depth }
    private enum Kind: String, Codable { case inset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .inset:
            self = .inset(
                fraction: try c.decode(Double.self, forKey: .fraction),
                depth: try c.decodeIfPresent(Double.self, forKey: .depth) ?? 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .inset(fraction, depth):
            try c.encode(Kind.inset, forKey: .kind)
            try c.encode(fraction, forKey: .fraction)
            try c.encode(depth, forKey: .depth)
        }
    }
}

/// The optimization pass's real geometry work: weld coincident (and
/// near-coincident) vertices on every geometry leaf, removing the split/seam
/// duplicates that inflate a mesh's vertex count for export. `weldDistance` is
/// the merge threshold in local units and is intended as a small epsilon that
/// folds duplicated seam vertices — not an arbitrary decimation knob (a large
/// threshold on a convex mesh collapses it, which MeshKit's welder rejects).
/// Authored alongside the LOD manifest.
public struct OptimizationSpec: Codable, Sendable, Equatable {
    /// Coincident-vertex weld epsilon (> 0) applied to each geometry leaf.
    public var weldDistance: Double

    public init(weldDistance: Double) {
        self.weldDistance = weldDistance
    }
}
