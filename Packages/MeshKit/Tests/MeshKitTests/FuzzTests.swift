import Testing
import Foundation
@testable import MeshKit

/// Invariant 7: random meshes × random valid selections × random params —
/// invariants must hold or the op must have thrown a precondition error.
/// No third outcome (crash / silent garbage).
@Suite("Property-based fuzzing")
struct FuzzTests {

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Random healthy fixture: grid of random size, optionally pre-extruded,
    /// with jittered vertex heights (keeps topology manifold, varies geometry).
    func randomMesh(_ rng: inout SplitMix64) -> HalfEdgeMesh {
        var mesh = Bool.random(using: &rng) ? Fixtures.cube()
                                            : Fixtures.grid(Int.random(in: 1...4, using: &rng))
        for v in mesh.vertexOrder {
            var p = mesh.positions[v]!
            p.z += Double.random(in: -0.05...0.05, using: &rng)
            mesh.setPosition(p, for: v)
        }
        return mesh
    }

    func randomFaces(_ mesh: HalfEdgeMesh, _ rng: inout SplitMix64) -> Set<FaceID> {
        let count = Int.random(in: 1...max(1, mesh.faceCount / 2), using: &rng)
        return Set(mesh.faceOrder.shuffled(using: &rng).prefix(count))
    }

    /// Seeds come from the committed corpus (`FuzzCorpus.swift`): pinned
    /// regression seeds + a deterministic sweep, deepened in CI via
    /// `MESHKIT_FUZZ_ITERATIONS`.
    @Test(arguments: FuzzCorpus.allSeeds)
    func fuzzOps(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let mesh = randomMesh(&rng)
        let original = mesh

        for opIndex in 0..<3 {
            let result: MeshOpResult?
            do {
                switch (Int(seed % 11) + opIndex) % 11 {
                case 0:
                    result = try ExtrudeFaces.apply(mesh, selection: .faces(randomFaces(mesh, &rng)),
                                                    params: .init(distance: Double.random(in: 0.1...2, using: &rng)))
                case 1:
                    result = try InsetFaces.apply(mesh, selection: .faces(randomFaces(mesh, &rng)),
                                                  params: .init(fraction: Double.random(in: 0.05...0.95, using: &rng)))
                case 2:
                    result = try DeleteComponents.apply(mesh, selection: .faces(randomFaces(mesh, &rng)))
                case 3:
                    result = try MergeVertices.apply(
                        mesh,
                        selection: .vertices(Set(mesh.positions.keys)),
                        params: .byDistance(Double.random(in: 0.01...0.5, using: &rng)))
                case 4:
                    let edges = Array(mesh.edgeFaceMap.keys).sorted(by: <)
                    let pick = Set(edges.shuffled(using: &rng)
                        .prefix(Int.random(in: 1...3, using: &rng)))
                    result = try BevelEdges.apply(mesh, selection: .edges(pick),
                                                  params: .init(width: Double.random(in: 0.01...0.6, using: &rng)))
                case 5:
                    let edges = Array(mesh.edgeFaceMap.keys).sorted(by: <)
                    let seedEdge = edges[Int.random(in: 0..<edges.count, using: &rng)]
                    result = try LoopCut.apply(mesh, selection: .edges([seedEdge]), params: .init())
                case 6:
                    // Mirror the whole mesh across a plane just below it on a
                    // random axis: no crossing, no on-plane welds → clean doubling
                    // (closed meshes double into two shells, open ones into two).
                    let axis = Mirror.Axis.allCases.randomElement(using: &rng)!
                    let k = Mirror.axisIndex(axis)
                    let minCoord = mesh.positions.values.map { $0[k] }.min()!
                    result = try Mirror.apply(mesh, selection: .faces(Set(mesh.faceOrder)),
                                              params: .init(axis: axis, coordinate: minCoord - 1))
                case 7:
                    // Solidify the whole mesh — refused loudly on closed input
                    // (no boundary), shells the open grids. Thin shell avoids
                    // self-intersection on the jittered surface.
                    result = try Solidify.apply(mesh, selection: .faces(Set(mesh.faceOrder)),
                                                params: .init(thickness: 0.05))
                case 8:
                    // Catmull-Clark subdivide the whole mesh: always valid on a
                    // healthy closed/open manifold, so it should never refuse
                    // here — the invariant suite guards the smoothed result.
                    result = try SubdivideCatmullClark.apply(
                        mesh, selection: .faces(Set(mesh.faceOrder)),
                        params: .init(levels: Int.random(in: 1...2, using: &rng)))
                case 9:
                    // Lattice/FFD bake: fit a cage to the mesh bounds, jitter every
                    // control point, deform all vertices. A jitter that folds a face
                    // to zero area is a valid loud refusal (caught below).
                    var lo = SIMD3(Double.infinity, .infinity, .infinity)
                    var hi = SIMD3(-Double.infinity, -.infinity, -.infinity)
                    for p in mesh.positions.values {
                        lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                        hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
                    }
                    // Pad so the whole mesh sits strictly inside the cage.
                    lo -= SIMD3(0.5, 0.5, 0.5); hi += SIMD3(0.5, 0.5, 0.5)
                    let interp = LatticeCage.Interpolation.allCases.randomElement(using: &rng)!
                    let res = LatticeCage.Resolution(l: Int.random(in: 2...4, using: &rng),
                                                     m: Int.random(in: 2...4, using: &rng),
                                                     n: Int.random(in: 2...4, using: &rng))
                    var cage = LatticeCage.fitted(min: lo, max: hi, resolution: res,
                                                  interpolation: interp, affectOutside: true)
                    cage.controlPoints = cage.controlPoints.map {
                        $0 + SIMD3(Double.random(in: -0.15...0.15, using: &rng),
                                   Double.random(in: -0.15...0.15, using: &rng),
                                   Double.random(in: -0.15...0.15, using: &rng))
                    }
                    result = try LatticeDeform.apply(mesh, selection: .faces(Set(mesh.faceOrder)),
                                                     params: .init(cage: cage))
                default:
                    // Live-vertex-edit path: proportional-falloff-weighted nudge
                    // of a random seed's neighborhood, exactly as the drag layer
                    // computes it. May collapse a face → loud refusal is valid.
                    let seedVert = mesh.vertexOrder.shuffled(using: &rng).first!
                    let radius = Double.random(in: 0.1...2, using: &rng)
                    let curve = ProportionalFalloff.Curve.allCases.randomElement(using: &rng)!
                    let weights = ProportionalFalloff.weights(
                        in: mesh, seeds: [seedVert], radius: radius, curve: curve)
                    let delta = SIMD3(Double.random(in: -0.5...0.5, using: &rng),
                                      Double.random(in: -0.5...0.5, using: &rng),
                                      Double.random(in: -0.5...0.5, using: &rng))
                    let targets = weights.mapValues { w in delta * w }
                    let abs = Dictionary(uniqueKeysWithValues:
                        targets.map { ($0.key, mesh.positions[$0.key]! + $0.value) })
                    result = try SetVertexPositions.apply(
                        mesh, selection: .vertices(Set(abs.keys)),
                        params: .init(positions: abs))
                }
            } catch is MeshOpError {
                result = nil // loud precondition refusal is a valid outcome
            }

            if let result {
                #expect(MeshInvariants.violations(in: result.mesh).isEmpty,
                        "op produced invariant violations on seed \(seed)/\(opIndex)")
                // Purity: input mesh must never mutate.
                #expect(mesh == original)
                // Round-trip through flat arrays keeps counts.
                let re = try MeshIO.mesh(from: MeshIO.flat(from: result.mesh))
                #expect(re.faceCount == result.mesh.faceCount)
                #expect(re.edgeCount == result.mesh.edgeCount)
            }
        }
    }
}
