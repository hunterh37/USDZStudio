import Foundation
import EditingKit
import MeshKit
import USDCore

/// Geometric ground truth read straight off the stage — bboxes, mesh
/// extraction, ray casting, interpenetration (docs/AGENT_MCP_PLAN.md §3.3/§4:
/// "measure the B-rep, don't trust the script").
public enum GeometryProbe {

    // MARK: - Axis-aligned bounding boxes

    public struct BBox: Sendable, Hashable {
        public var min: [Double]  // [x, y, z]
        public var max: [Double]

        public init(min: [Double], max: [Double]) {
            self.min = min
            self.max = max
        }

        public var size: [Double] { [max[0] - min[0], max[1] - min[1], max[2] - min[2]] }
        public var center: [Double] {
            [(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2]
        }
        /// Longest edge of the box — the "how big is this thing" scalar.
        public var maxExtent: Double { size.max() ?? 0 }

        public func union(_ other: BBox) -> BBox {
            BBox(
                min: [Swift.min(min[0], other.min[0]), Swift.min(min[1], other.min[1]), Swift.min(min[2], other.min[2])],
                max: [Swift.max(max[0], other.max[0]), Swift.max(max[1], other.max[1]), Swift.max(max[2], other.max[2])])
        }

        /// Overlap volume with another box (0 when disjoint or merely touching).
        public func overlapVolume(with other: BBox) -> Double {
            let dx = Swift.min(max[0], other.max[0]) - Swift.max(min[0], other.min[0])
            let dy = Swift.min(max[1], other.max[1]) - Swift.max(min[1], other.min[1])
            let dz = Swift.min(max[2], other.max[2]) - Swift.max(min[2], other.min[2])
            guard dx > 0, dy > 0, dz > 0 else { return 0 }
            return dx * dy * dz
        }

        public var asJSON: JSONValue {
            .object([
                "min": .array(min.map { .number($0) }),
                "max": .array(max.map { .number($0) }),
                "size": .array(size.map { .number($0) }),
                "center": .array(center.map { .number($0) }),
            ])
        }
    }

    /// World-space bbox of a prim subtree, from mesh `points` attributes
    /// transformed by each mesh's world matrix. `nil` when the subtree
    /// carries no point geometry.
    public static func worldBBox(of path: PrimPath, in stage: any USDStageProtocol) -> BBox? {
        guard let prim = stage.prim(at: path) else { return nil }
        var box: BBox?
        for descendant in prim.flattened() {
            guard let points = points(of: descendant) else { continue }
            let matrix = stage.worldMatrix(at: descendant.path)
            for p in points {
                let w = transform(point: p, by: matrix)
                let pointBox = BBox(min: w, max: w)
                box = box.map { $0.union(pointBox) } ?? pointBox
            }
        }
        return box
    }

    // MARK: - Mesh extraction

    /// Raw `points` positions of a single prim, when it has any.
    ///
    /// Accepts both the canonical `point3f[]` (`.float3Array`) that every native
    /// authoring path writes and a flat `double[]` (`.doubleArray`) — the latter
    /// is a legal USD encoding that arrives when reopening an externally authored
    /// USDZ whose points are double-precision (`stage_snapshot.py` decodes a true
    /// `double[]` to `.doubleArray`). Without this fallback such a mesh is
    /// invisible to check_mesh, world-bbox, and raycast even though its geometry
    /// is perfectly valid.
    static func points(of prim: Prim) -> [[Double]]? {
        let flat: [Double]
        switch prim.attribute(named: "points")?.value {
        case .float3Array(let v), .doubleArray(let v): flat = v
        default: return nil
        }
        guard flat.count >= 3 else { return nil }
        // Written imperatively with explicit types: the equivalent
        // `stride(...).map { [flat[$0], flat[$0+1], flat[$0+2]] }` one-liner
        // intermittently blows the Swift type-checker's time budget on CI.
        var triples: [[Double]] = []
        triples.reserveCapacity(flat.count / 3)
        var i = 0
        while i + 2 < flat.count {
            let x = Double(flat[i])
            let y = Double(flat[i + 1])
            let z = Double(flat[i + 2])
            triples.append([x, y, z])
            i += 3
        }
        return triples
    }

    /// Build a MeshKit `FlatMesh` from a Mesh prim's authored topology.
    public static func flatMesh(of prim: Prim) throws -> FlatMesh {
        guard let pts = points(of: prim),
              case .intArray(let counts)? = prim.attribute(named: "faceVertexCounts")?.value,
              case .intArray(let indices)? = prim.attribute(named: "faceVertexIndices")?.value
        else {
            throw ToolError.invalidParams(
                "prim \(prim.path) has no mesh topology (points/faceVertexCounts/faceVertexIndices)")
        }
        let skinned = prim.relationships.contains { $0.name == "skel:skeleton" }
            || prim.attribute(named: "primvars:skel:jointIndices") != nil
        return FlatMesh(
            points: pts.map { SIMD3($0[0], $0[1], $0[2]) },
            faceVertexCounts: counts,
            faceVertexIndices: indices,
            hasSkeletalBinding: skinned)
    }

    /// Author a `FlatMesh` back onto a prim as USD attributes.
    /// Author the core USD Mesh attributes for `flat`.
    ///
    /// `subdivisionScheme` defaults to `"none"`: USD's own default is
    /// `catmullClark`, so a polygonal cage we intend to display as-authored is
    /// otherwise treated as a subdivision control cage and rendered as a rounded
    /// blob (boxes → pills). Callers that genuinely want a subdivision surface can
    /// pass `subdivisionScheme: "catmullClark"`. See issue #97.
    public static func meshAttributes(
        from flat: FlatMesh,
        subdivisionScheme: String = "none"
    ) -> [Attribute] {
        [
            Attribute(name: "points", value: .float3Array(flat.points.flatMap { [$0.x, $0.y, $0.z] })),
            Attribute(name: "faceVertexCounts", value: .intArray(flat.faceVertexCounts)),
            Attribute(name: "faceVertexIndices", value: .intArray(flat.faceVertexIndices)),
            Attribute(name: "subdivisionScheme", value: .token(subdivisionScheme), isUniform: true),
        ]
    }

    // MARK: - Ray casting

    public struct RayHit: Sendable, Hashable {
        public var path: PrimPath
        public var distance: Double
        public var point: [Double]
    }

    /// Cast a world-space ray against every mesh in the stage
    /// (Möller–Trumbore per triangle after fan-triangulating face loops).
    public static func raycast(
        origin: [Double], direction: [Double], in stage: any USDStageProtocol
    ) -> RayHit? {
        let dirLength = sqrt(direction.map { $0 * $0 }.reduce(0, +))
        guard dirLength > 1e-12 else { return nil }
        let dir = direction.map { $0 / dirLength }

        var best: RayHit?
        for root in stage.rootPrims {
            for prim in root.flattened() {
                guard let pts = points(of: prim),
                      case .intArray(let counts)? = prim.attribute(named: "faceVertexCounts")?.value,
                      case .intArray(let indices)? = prim.attribute(named: "faceVertexIndices")?.value
                else { continue }
                let matrix = stage.worldMatrix(at: prim.path)
                let world = pts.map { transform(point: $0, by: matrix) }

                var cursor = 0
                for count in counts {
                    defer { cursor += count }
                    guard count >= 3, cursor + count <= indices.count else { continue }
                    for i in 1..<(count - 1) {
                        let a = world[indices[cursor]]
                        let b = world[indices[cursor + i]]
                        let c = world[indices[cursor + i + 1]]
                        guard let t = intersect(origin: origin, dir: dir, a: a, b: b, c: c),
                              t < (best?.distance ?? .infinity)
                        else { continue }
                        best = RayHit(
                            path: prim.path,
                            distance: t,
                            point: [origin[0] + dir[0] * t, origin[1] + dir[1] * t, origin[2] + dir[2] * t])
                    }
                }
            }
        }
        return best
    }

    /// Möller–Trumbore ray/triangle; returns distance `t ≥ 0` or nil.
    static func intersect(
        origin: [Double], dir: [Double], a: [Double], b: [Double], c: [Double]
    ) -> Double? {
        let e1 = sub(b, a), e2 = sub(c, a)
        let p = cross(dir, e2)
        let det = dot(e1, p)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        let s = sub(origin, a)
        let u = dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = cross(s, e1)
        let v = dot(dir, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = dot(e2, q) * inv
        return t >= 0 ? t : nil
    }

    // MARK: - Interpenetration (§4 gate 4)

    /// Pairs of sibling geometry subtrees whose world bboxes overlap by more
    /// than `tolerance` of the smaller box's volume.
    public static func interpenetrations(
        in stage: any USDStageProtocol, tolerance: Double = 0.05
    ) -> [(a: PrimPath, b: PrimPath, overlapVolume: Double)] {
        var boxes: [(PrimPath, BBox)] = []
        for root in stage.rootPrims {
            for prim in root.flattened() where points(of: prim) != nil {
                if let box = worldBBox(of: prim.path, in: stage) { boxes.append((prim.path, box)) }
            }
        }
        var out: [(PrimPath, PrimPath, Double)] = []
        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                let (pa, ba) = boxes[i]
                let (pb, bb) = boxes[j]
                // Nested prims legitimately share space; only compare disjoint subtrees.
                guard !pa.isAncestor(of: pb), !pb.isAncestor(of: pa) else { continue }
                let overlap = ba.overlapVolume(with: bb)
                let smaller = min(volume(ba), volume(bb))
                if smaller > 0, overlap > smaller * tolerance {
                    out.append((pa, pb, overlap))
                }
            }
        }
        return out
    }

    static func volume(_ box: BBox) -> Double {
        let s = box.size
        return s[0] * s[1] * s[2]
    }

    // MARK: - Vector helpers

    static func transform(point p: [Double], by m: [Double]) -> [Double] {
        // Row-vector convention: p' = p · M (EditingKit Matrix4).
        [
            p[0] * m[0] + p[1] * m[4] + p[2] * m[8] + m[12],
            p[0] * m[1] + p[1] * m[5] + p[2] * m[9] + m[13],
            p[0] * m[2] + p[1] * m[6] + p[2] * m[10] + m[14],
        ]
    }

    static func sub(_ a: [Double], _ b: [Double]) -> [Double] { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
    static func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }
}
