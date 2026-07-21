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
                switch (Int(seed % 6) + opIndex) % 6 {
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
                default:
                    let edges = Array(mesh.edgeFaceMap.keys).sorted(by: <)
                    let seedEdge = edges[Int.random(in: 0..<edges.count, using: &rng)]
                    result = try LoopCut.apply(mesh, selection: .edges([seedEdge]), params: .init())
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
