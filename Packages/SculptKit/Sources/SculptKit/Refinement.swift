import Foundation

/// A real geometry-refinement operation applied to a component's mesh during
/// the `formRefinement` pass. Unlike the review-only passes, these author actual
/// topology changes: the AgentMCP executor reads the authored prim back into a
/// `MeshKit.HalfEdgeMesh`, applies the op over the whole mesh, and re-authors
/// the result. SculptKit only carries the declarative intent — it performs no
/// mesh surgery itself, keeping the module a pure leaf.
///
/// v1 exposes `inset` (adds surface definition — a recessed inner ring on every
/// face) and `subdivide` (Catmull-Clark smoothing — rounds faceted low-poly
/// stock). Both apply cleanly whole-mesh, so they are always valid on any
/// authored primitive; more ops can be added behind new cases.
public enum MeshRefinement: Codable, Sendable, Equatable {
    /// Inset every face: each face grows a recessed inner ring. `fraction` is
    /// how far each corner moves toward the face centroid (0 < fraction < 1);
    /// `depth` offsets the inner ring along the face normal (negative = inward).
    case inset(fraction: Double, depth: Double)

    /// Catmull-Clark subdivide the whole mesh `levels` times (≥ 1): every face
    /// becomes quads and vertices are smoothed toward the limit surface. Valid
    /// on every build primitive (closed solids and the open plane), it targets
    /// the "lumpy / subdivision rounding" complaint directly.
    case subdivide(levels: Int)

    // Sculpt-accuracy P4 (#85): expressiveness beyond primitives + inset. The
    // F5 finding is that 5 primitives + inset cannot represent a wedge profile,
    // chamfered shoulder lines, or a pulled intake/splitter — capping the
    // achievable silhouette IoU (~0.46 plateau). These ops stay declarative
    // (SculptKit performs no mesh surgery); the executor resolves each into a
    // deterministic MeshKit selection + op.

    /// Linearly scale the cross-section along `axis`: 1× at the low end,
    /// `scale`× at the high end (0 < scale, ≠ 1). The wedge/taper op — an
    /// Aventador profile is a tapered box before it is anything else. Executed
    /// as a fitted 2×2×2 FFD lattice with the high-end control layer scaled.
    case taper(axis: RefinementAxis, scale: Double)

    /// Chamfer sharp edges: every edge whose dihedral angle exceeds
    /// `angleDegrees` is a candidate; a deterministic non-adjacent subset is
    /// bevelled by `width` (> 0). Softens box/cylinder shoulder lines into the
    /// facet lines a real body panel shows.
    case bevel(width: Double, angleDegrees: Double)

    /// Pull the faces facing `direction` outward by `distance` (≠ 0, negative
    /// recesses them): nose splitters, intakes, cabin bulges — local silhouette
    /// features a whole-primitive transform cannot express.
    case extrude(direction: RefinementDirection, distance: Double)

    private enum CodingKeys: String, CodingKey {
        case kind, fraction, depth, levels, axis, scale, width, angleDegrees, direction, distance
    }
    private enum Kind: String, Codable { case inset, subdivide, taper, bevel, extrude }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .inset:
            self = .inset(
                fraction: try c.decode(Double.self, forKey: .fraction),
                depth: try c.decodeIfPresent(Double.self, forKey: .depth) ?? 0)
        case .subdivide:
            self = .subdivide(levels: try c.decodeIfPresent(Int.self, forKey: .levels) ?? 1)
        case .taper:
            self = .taper(
                axis: try c.decode(RefinementAxis.self, forKey: .axis),
                scale: try c.decode(Double.self, forKey: .scale))
        case .bevel:
            self = .bevel(
                width: try c.decode(Double.self, forKey: .width),
                angleDegrees: try c.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 30)
        case .extrude:
            self = .extrude(
                direction: try c.decode(RefinementDirection.self, forKey: .direction),
                distance: try c.decode(Double.self, forKey: .distance))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .inset(fraction, depth):
            try c.encode(Kind.inset, forKey: .kind)
            try c.encode(fraction, forKey: .fraction)
            try c.encode(depth, forKey: .depth)
        case let .subdivide(levels):
            try c.encode(Kind.subdivide, forKey: .kind)
            try c.encode(levels, forKey: .levels)
        case let .taper(axis, scale):
            try c.encode(Kind.taper, forKey: .kind)
            try c.encode(axis, forKey: .axis)
            try c.encode(scale, forKey: .scale)
        case let .bevel(width, angleDegrees):
            try c.encode(Kind.bevel, forKey: .kind)
            try c.encode(width, forKey: .width)
            try c.encode(angleDegrees, forKey: .angleDegrees)
        case let .extrude(direction, distance):
            try c.encode(Kind.extrude, forKey: .kind)
            try c.encode(direction, forKey: .direction)
            try c.encode(distance, forKey: .distance)
        }
    }
}

/// The unsigned model-space axis a refinement varies along.
public enum RefinementAxis: String, Codable, Sendable, Equatable, CaseIterable {
    case x, y, z
}

/// A signed model-space direction: which way a refinement faces.
public enum RefinementDirection: String, Codable, Sendable, Equatable, CaseIterable {
    case posX = "+x", negX = "-x"
    case posY = "+y", negY = "-y"
    case posZ = "+z", negZ = "-z"

    /// The unit vector for the direction, as (x, y, z).
    public var unitVector: (x: Double, y: Double, z: Double) {
        switch self {
        case .posX: return (1, 0, 0)
        case .negX: return (-1, 0, 0)
        case .posY: return (0, 1, 0)
        case .negY: return (0, -1, 0)
        case .posZ: return (0, 0, 1)
        case .negZ: return (0, 0, -1)
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
