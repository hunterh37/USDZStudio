import Foundation

/// Single edge-loop cut via quad-strip traversal (specs/mesh-editing.md v1).
///
/// Starting from one seed edge, the cut walks the strip of quads reachable
/// through successive *opposite* edges — the classic "loop cut" ring — placing
/// a midpoint vertex on every crossed rung edge and splitting each quad in the
/// strip into two along the segment joining its two rung midpoints.
///
/// The strip is discovered in both directions from the seed and terminates
/// either by closing back on the seed (a ring, e.g. around a cube) or by
/// reaching a boundary edge (an open strip, e.g. across a grid).
///
/// Strict v1 preconditions (fail loudly, per the op contract):
/// - selection is exactly one seed edge that borders at least one face
/// - every face the strip passes through is a quad (4-vertex loop)
/// - rungs bordering > 2 faces are non-manifold and refused
/// - `cuts == 1` (multi-segment loop cut is Phase 8)
///
/// Predicted delta (rings and strips alike): each rung contributes one vertex,
/// each quad contributes one face, and E grows by rung + face count — one new
/// edge per split rung plus one cut edge per quad. Euler characteristic is
/// preserved (ΔV − ΔE + ΔF = 0), and midpoints keep every face planar so a
/// closed mesh's analytic volume is unchanged.
public enum LoopCut: MeshOp {
    public static let name = "Loop Cut"

    public struct Params: Sendable {
        /// Number of parallel cuts. v1 supports exactly one.
        public var cuts: Int
        public init(cuts: Int = 1) { self.cuts = cuts }
    }

    public static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection,
                             params: Params) throws -> MeshOpResult {
        guard case .edges(let edges) = selection, !edges.isEmpty else {
            throw MeshOpError.emptySelection
        }
        guard edges.count == 1, let seed = edges.first else {
            throw MeshOpError.preconditionFailed(
                "loop cut takes exactly one seed edge; got \(edges.count)")
        }
        guard params.cuts == 1 else {
            throw MeshOpError.preconditionFailed(
                "multi-segment loop cut (cuts = \(params.cuts)) is Phase 8; v1 supports a single cut")
        }

        let edgeFaces = mesh.edgeFaceMap
        guard let seedFaces = edgeFaces[seed], !seedFaces.isEmpty else {
            throw MeshOpError.unknownComponent("edge (\(seed.a.rawValue),\(seed.b.rawValue))")
        }

        // MARK: Strip traversal

        /// The edge opposite `rung` in a quad `face`. `rung` is always an edge
        /// of `face` by construction, so only the quad requirement can fail.
        func oppositeRung(in face: FaceID, to rung: EdgeKey) throws -> EdgeKey {
            let loop = mesh.faceLoops[face]!
            guard loop.count == 4 else {
                throw MeshOpError.preconditionFailed(
                    "face \(face.rawValue) has \(loop.count) sides; loop cut traverses quads only")
            }
            for i in loop.indices where EdgeKey(loop[i], loop[(i + 1) % 4]) == rung {
                return EdgeKey(loop[(i + 2) % 4], loop[(i + 3) % 4])
            }
            // coverage:disable — rung is always an edge of `face`: the seed borders
            // its own faces, and every later rung is the edge crossed into the face.
            throw MeshOpError.preconditionFailed("edge not on face \(face.rawValue)")
            // coverage:enable
        }

        /// Face across `rung` other than `face`; nil at a boundary. Throws on a
        /// non-manifold rung (> 2 incident faces).
        func neighbor(across rung: EdgeKey, from face: FaceID) throws -> FaceID? {
            let adj = edgeFaces[rung] ?? []
            guard adj.count <= 2 else {
                throw MeshOpError.nonManifoldRegion(
                    "edge (\(rung.a.rawValue),\(rung.b.rawValue)) borders \(adj.count) faces")
            }
            return adj.first { $0 != face }
        }

        var visited = Set<FaceID>()

        /// Walk from `startFace` through opposite edges until the strip closes
        /// back on the seed or hits a boundary. Returns the faces crossed (in
        /// order) and the exit rungs between them (the seed rung is not
        /// re-emitted; a closing exit that equals the seed is not emitted).
        func walk(from startFace: FaceID) throws -> (faces: [FaceID], exits: [EdgeKey], closed: Bool) {
            var faces: [FaceID] = [], exits: [EdgeKey] = []
            var face: FaceID? = startFace
            var rung = seed
            while let cur = face {
                guard visited.insert(cur).inserted else {
                    // coverage:disable — a clean quad strip closes on the seed or ends
                    // at a boundary before revisiting a face; re-entry means a pinched
                    // or branching strip we refuse rather than hang.
                    throw MeshOpError.preconditionFailed(
                        "strip re-enters face \(cur.rawValue) without closing; loop cut needs a simple quad strip")
                    // coverage:enable
                }
                faces.append(cur)
                let exit = try oppositeRung(in: cur, to: rung)
                if exit == seed { return (faces, exits, true) }
                exits.append(exit)
                face = try neighbor(across: exit, from: cur)
                rung = exit
            }
            return (faces, exits, false)
        }

        var (orderedFaces, exits, closed) = try walk(from: seedFaces[0])
        var orderedRungs = [seed] + exits

        // Open interior seed: continue the strip through the other seed face and
        // prepend that half (walked away from the seed, so reverse to prepend).
        if !closed, seedFaces.count == 2 {
            let (backFaces, backExits, _) = try walk(from: seedFaces[1])
            orderedFaces = backFaces.reversed() + orderedFaces
            orderedRungs = backExits.reversed() + orderedRungs
        }

        // MARK: Rebuild

        let rungSet = Set(orderedRungs)
        var out = mesh

        // One shared midpoint per rung.
        var midpoint: [EdgeKey: VertexID] = [:]
        for r in orderedRungs {
            let p = mesh.positions[r.a]!, q = mesh.positions[r.b]!
            midpoint[r] = out.addVertex((p + q) / 2)
        }

        var cutEdges = Set<EdgeKey>()
        for f in orderedFaces {
            let loop = mesh.faceLoops[f]!
            // A strip quad's two rung edges are its entry and exit — opposite by
            // construction (indices i and i+2).
            let rungIndices = loop.indices.filter {
                rungSet.contains(EdgeKey(loop[$0], loop[($0 + 1) % 4]))
            }
            guard rungIndices.count == 2, (rungIndices[1] - rungIndices[0]) % 2 == 0 else {
                // coverage:disable — entry/exit rungs of a traversed quad are always
                // the opposite pair; a different count would contradict the walk.
                throw MeshOpError.preconditionFailed(
                    "face \(f.rawValue) has adjacent (non-opposite) rung edges; loop cut needs a clean strip")
                // coverage:enable
            }
            let p = rungIndices[0]
            let a = loop[p], b = loop[(p + 1) % 4], c = loop[(p + 2) % 4], d = loop[(p + 3) % 4]
            let m1 = midpoint[EdgeKey(a, b)]!, m2 = midpoint[EdgeKey(c, d)]!

            // Reuse `f` for one half; add the other. Winding follows [a,b,c,d].
            out.replaceLoop([a, m1, m2, d], for: f)
            let added = out.addFace([m1, b, c, m2])
            for (name, members) in mesh.subsets where members.contains(f) {
                out.addFaceToSubset(added, subset: name)
            }
            cutEdges.insert(EdgeKey(m1, m2))
        }

        let predicted = TopologyDelta(vertices: orderedRungs.count,
                                      edges: orderedRungs.count + orderedFaces.count,
                                      faces: orderedFaces.count)
        try OpSupport.verify(before: mesh, after: out, predicted: predicted)
        return MeshOpResult(mesh: out, resultSelection: .edges(cutEdges), delta: predicted)
    }
}
