import Testing
import Foundation
@testable import MeshKit

@Suite("SetVertexPositions")
struct SetVertexPositionsTests {

    private let tolerance = 1e-12

    @Test func movesOnlyTheListedVertexAndReportsZeroDelta() throws {
        let cube = Fixtures.cube()
        let v = cube.vertexOrder[0]
        let target = cube.positions[v]! + SIMD3(0.1, -0.2, 0.05)
        let r = try SetVertexPositions.apply(
            cube, selection: .vertices([v]),
            params: .init(positions: [v: target]))

        #expect(r.delta == TopologyDelta(vertices: 0, edges: 0, faces: 0))
        #expect(simd_length(r.mesh.positions[v]! - target) < tolerance)
        for other in cube.vertexOrder where other != v {
            #expect(r.mesh.positions[other]! == cube.positions[other]!)
        }
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func passesTheSelectionThrough() throws {
        let cube = Fixtures.cube()
        let v = cube.vertexOrder[0]
        let sel = ComponentSelection.vertices([v])
        let r = try SetVertexPositions.apply(
            cube, selection: sel, params: .init(positions: [v: SIMD3(9, 9, 9)]))
        #expect(r.resultSelection == sel)
    }

    @Test func emptyPositionsThrowsPrecondition() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.preconditionFailed("no vertex positions supplied — nothing to do")) {
            _ = try SetVertexPositions.apply(
                cube, selection: .vertices([]), params: .init(positions: [:]))
        }
    }

    @Test func unknownVertexThrows() {
        let cube = Fixtures.cube()
        let ghost = VertexID(9999)
        #expect(throws: MeshOpError.unknownComponent("vertex 9999")) {
            _ = try SetVertexPositions.apply(
                cube, selection: .vertices([ghost]),
                params: .init(positions: [ghost: SIMD3(0, 0, 0)]))
        }
    }

    @Test func nonFiniteCoordinateIsRejected() {
        let cube = Fixtures.cube()
        let v = cube.vertexOrder[0]
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(throws: MeshOpError.self) {
                _ = try SetVertexPositions.apply(
                    cube, selection: .vertices([v]),
                    params: .init(positions: [v: SIMD3(bad, 0, 0)]))
            }
        }
    }

    @Test func nanPassesRangeChecksButIsStillCaught() {
        // Regression guard: NaN fails every comparison, so a naive `< lo || > hi`
        // range check would let it through. The explicit isFinite guard catches it.
        let grid = Fixtures.grid(1)
        let v = grid.vertexOrder[0]
        #expect(!(Double.nan < 0) && !(Double.nan > 1)) // documents the trap
        #expect(throws: MeshOpError.self) {
            _ = try SetVertexPositions.apply(
                grid, selection: .vertices([v]),
                params: .init(positions: [v: SIMD3(0, .nan, 0)]))
        }
    }

    @Test func collapsingAFaceToZeroAreaViolatesInvariants() {
        // Move a quad corner onto its loop-adjacent neighbor → coincident
        // vertices → degenerate face → post-op invariant check throws.
        let grid = Fixtures.grid(1)
        let a = grid.vertexOrder[0]
        let b = grid.vertexOrder[1]
        #expect(throws: MeshOpError.self) {
            _ = try SetVertexPositions.apply(
                grid, selection: .vertices([a]),
                params: .init(positions: [a: grid.positions[b]!]))
        }
    }

    @Test func undoNeutrality_reapplyingOriginalPositionsRestoresHash() throws {
        let grid = Fixtures.grid(2)
        let moved = Set(grid.vertexOrder.prefix(3))
        let targets = Dictionary(uniqueKeysWithValues:
            moved.map { ($0, grid.positions[$0]! + SIMD3(0, 0, 0.3)) })
        let r = try SetVertexPositions.apply(
            grid, selection: .vertices(moved), params: .init(positions: targets))
        let back = Dictionary(uniqueKeysWithValues:
            moved.map { ($0, grid.positions[$0]!) })
        let restored = try SetVertexPositions.apply(
            r.mesh, selection: .vertices(moved), params: .init(positions: back))
        #expect(restored.mesh.topologyHash == grid.topologyHash)
    }
}
