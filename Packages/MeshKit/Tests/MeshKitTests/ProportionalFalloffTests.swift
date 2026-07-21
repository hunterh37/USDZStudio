import Testing
import Foundation
@testable import MeshKit

@Suite("ProportionalFalloff")
struct ProportionalFalloffTests {

    private let tol = 1e-12

    // MARK: Curve math

    @Test func curveEndpointsAndClamping() {
        for c in ProportionalFalloff.Curve.allCases {
            #expect(abs(c.weight(0) - 1) < tol)          // full weight at the seed
            #expect(c.weight(2) == c.weight(1))          // clamps t > 1
            #expect(c.weight(-1) == c.weight(0))         // clamps t < 0
        }
        #expect(ProportionalFalloff.Curve.constant.weight(0.5) == 1)
        #expect(abs(ProportionalFalloff.Curve.linear.weight(0.25) - 0.75) < tol)
        #expect(abs(ProportionalFalloff.Curve.smooth.weight(0.5) - 0.5) < tol)   // symmetric midpoint
        #expect(abs(ProportionalFalloff.Curve.sphere.weight(0.5) - (0.75).squareRoot()) < tol)
        #expect(ProportionalFalloff.Curve.linear.weight(1) == 0)
        #expect(ProportionalFalloff.Curve.sphere.weight(1) == 0)
    }

    // MARK: weights()

    @Test func emptySeedsGiveEmptyMap() {
        let grid = Fixtures.grid(2)
        #expect(ProportionalFalloff.weights(in: grid, seeds: [], radius: 5).isEmpty)
    }

    @Test func nonPositiveRadiusReturnsOnlySeedsAtFullWeight() {
        let grid = Fixtures.grid(2)
        let seeds: Set<VertexID> = [grid.vertexOrder[0]]
        let w = ProportionalFalloff.weights(in: grid, seeds: seeds, radius: 0)
        #expect(w == [grid.vertexOrder[0]: 1])
    }

    @Test func seedsNotInMeshAreIgnored() {
        let grid = Fixtures.grid(1)
        let w = ProportionalFalloff.weights(
            in: grid, seeds: [VertexID(9999)], radius: 5)
        #expect(w.isEmpty)
    }

    @Test func seedAlwaysFullWeightNeighborsFalloffLinearly() {
        // grid(2): unit spacing. Seed a corner; radius 1 reaches its two
        // edge-neighbors at distance 1 → linear weight 0, the diagonal is
        // geodesic distance 2 (out of range) → omitted.
        let grid = Fixtures.grid(2)
        let corner = grid.vertexOrder[0] // (0,0,0)
        let w = ProportionalFalloff.weights(
            in: grid, seeds: [corner], radius: 1.5, curve: .linear)
        #expect(abs(w[corner]! - 1) < tol)
        // A vertex one edge away sits at distance 1 → weight 1 - 1/1.5.
        let neighbors = ProportionalFalloff.vertexAdjacency(in: grid)[corner]!
        for n in neighbors {
            #expect(abs(w[n]! - (1 - 1.0 / 1.5)) < 1e-9)
        }
    }

    @Test func verticesBeyondRadiusAreOmitted() {
        let grid = Fixtures.grid(3)
        let corner = grid.vertexOrder[0]
        let w = ProportionalFalloff.weights(in: grid, seeds: [corner], radius: 0.5)
        // Nearest neighbor is a full unit away → nothing but the seed qualifies.
        #expect(w == [corner: 1])
    }

    @Test func geodesicDistanceIsSymmetricAcrossSeeds() {
        // Two seeds: every vertex takes the min distance to either seed, so a
        // vertex between them gets the higher of the two weights.
        let grid = Fixtures.grid(4)
        let a = grid.vertexOrder.first { grid.positions[$0]! == SIMD3(0, 0, 0) }!
        let b = grid.vertexOrder.first { grid.positions[$0]! == SIMD3(4, 0, 0) }!
        let w = ProportionalFalloff.weights(in: grid, seeds: [a, b], radius: 10, curve: .linear)
        #expect(abs(w[a]! - 1) < tol)
        #expect(abs(w[b]! - 1) < tol)
        // Midpoint x=2 is distance 2 from each → weight 1 - 2/10.
        let mid = grid.vertexOrder.first { grid.positions[$0]! == SIMD3(2, 0, 0) }!
        #expect(abs(w[mid]! - (1 - 2.0 / 10)) < 1e-9)
    }

    @Test func adjacencyIsUndirectedAndComplete() {
        let grid = Fixtures.grid(1) // 4 verts, 1 quad
        let adj = ProportionalFalloff.vertexAdjacency(in: grid)
        // Each corner of a single quad touches exactly two loop-neighbors.
        for v in grid.vertexOrder {
            #expect(adj[v]!.count == 2)
        }
        // Symmetric.
        for (v, ns) in adj {
            for n in ns { #expect(adj[n]!.contains(v)) }
        }
    }

    @Test func isolatedSeedVertexHasNoNeighborsToRelax() {
        // A seed vertex with no incident faces has no adjacency entry; the
        // frontier drains immediately and only the seed carries weight.
        var mesh = Fixtures.grid(1)
        let iso = mesh.addVertex(SIMD3(10, 10, 10))
        let w = ProportionalFalloff.weights(in: mesh, seeds: [iso], radius: 5)
        #expect(w == [iso: 1])
    }

    @Test func staleFrontierEntriesAreSkipped() {
        // A denser grid forces multiple relaxations of the same vertex, i.e.
        // stale (distance-superseded) frontier entries — exercises the
        // `d > best[u]` continue branch. Result must still be correct.
        let grid = Fixtures.grid(4)
        let center = grid.vertexOrder.first { grid.positions[$0]! == SIMD3(2, 2, 0) }!
        let w = ProportionalFalloff.weights(in: grid, seeds: [center], radius: 3, curve: .smooth)
        #expect(abs(w[center]! - 1) < tol)
        // All weights within [0, 1].
        for v in w.values { #expect(v >= -tol && v <= 1 + tol) }
    }
}
