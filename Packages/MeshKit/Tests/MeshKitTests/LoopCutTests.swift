import Testing
import Foundation
@testable import MeshKit

@Suite("LoopCut")
struct LoopCutTests {

    // MARK: Happy paths

    /// A cube edge seeds a ring of 4 quads that closes on itself: V+4, E+8, F+4,
    /// χ stays 2, and midpoints keep the mesh a unit cube (volume unchanged).
    @Test func cubeRingIsClosedAndVolumePreserving() throws {
        let cube = Fixtures.cube()
        let r = try LoopCut.apply(cube, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                                  params: .init())
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 8, faces: 4))
        #expect(r.mesh.vertexCount == 12)
        #expect(r.mesh.edgeCount == 20)
        #expect(r.mesh.faceCount == 10)
        #expect(MeshInvariants.eulerCharacteristic(of: cube) == 2)
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
        #expect(abs(r.mesh.signedVolume - 1.0) < 1e-12)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
        // The cut is a 4-edge loop; result selection reports it.
        guard case .edges(let cut) = r.resultSelection else { Issue.record("expected edges"); return }
        #expect(cut.count == 4)
    }

    /// An interior grid edge cuts across the strip in *both* directions from the
    /// seed (exercises the backward walk). Open surface → χ preserved at 1.
    @Test func gridInteriorSeedCutsBothDirections() throws {
        let grid = Fixtures.grid(2) // 9 verts, 12 edges, 4 quads
        let r = try LoopCut.apply(grid, selection: .edges([EdgeKey(VertexID(1), VertexID(4))]),
                                  params: .init())
        #expect(r.delta == TopologyDelta(vertices: 3, edges: 5, faces: 2))
        #expect(r.mesh.vertexCount == 12)
        #expect(r.mesh.faceCount == 6)
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 1)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    /// A boundary seed walks a single direction (no backward pass) yet still
    /// spans the full column to the far boundary.
    @Test func gridBoundarySeedWalksOneDirection() throws {
        let grid = Fixtures.grid(2)
        let r = try LoopCut.apply(grid, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                                  params: .init())
        #expect(r.delta == TopologyDelta(vertices: 3, edges: 5, faces: 2))
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    /// New faces inherit the split face's subset (material) membership.
    @Test func splitFacesInheritSubset() throws {
        var cube = Fixtures.cube()
        cube.addFaceToSubset(FaceID(0), subset: "mat") // bottom face, on the ring
        let r = try LoopCut.apply(cube, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                                  params: .init())
        // Original face survives (reused half) plus one new half → 2 members.
        #expect(r.mesh.subsets["mat"]?.contains(FaceID(0)) == true)
        #expect((r.mesh.subsets["mat"]?.count ?? 0) == 2)
    }

    /// Purity + round-trip fidelity (invariant 8).
    @Test func isPureAndSurvivesRoundTrip() throws {
        let cube = Fixtures.cube()
        let before = cube
        let r = try LoopCut.apply(cube, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                                  params: .init())
        #expect(cube == before) // input never mutated
        let reimported = try MeshIO.mesh(from: MeshIO.flat(from: r.mesh))
        #expect(reimported.faceCount == r.mesh.faceCount)
        #expect(reimported.edgeCount == r.mesh.edgeCount)
    }

    // MARK: Refusals

    @Test func rejectsEmptyOrNonEdgeSelection() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try LoopCut.apply(cube, selection: .edges([]), params: .init())
        }
        #expect(throws: MeshOpError.emptySelection) {
            try LoopCut.apply(cube, selection: .faces([FaceID(0)]), params: .init())
        }
    }

    @Test func rejectsMultipleSeedEdges() {
        let cube = Fixtures.cube()
        #expect {
            try LoopCut.apply(cube, selection: .edges([
                EdgeKey(VertexID(0), VertexID(1)), EdgeKey(VertexID(2), VertexID(3))]),
                              params: .init())
        } throws: { ($0 as? MeshOpError) == .preconditionFailed("loop cut takes exactly one seed edge; got 2") }
    }

    @Test func rejectsMultiSegmentCut() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try LoopCut.apply(cube, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                              params: .init(cuts: 2))
        }
    }

    @Test func rejectsUnknownSeedEdge() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.unknownComponent("edge (100,101)")) {
            try LoopCut.apply(cube, selection: .edges([EdgeKey(VertexID(100), VertexID(101))]),
                              params: .init())
        }
    }

    /// The strip enters a triangle → refuse (quads only).
    @Test func rejectsNonQuadInStrip() throws {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0.5, 2, 0)],
            faceVertexCounts: [4, 3],
            faceVertexIndices: [0, 1, 2, 3, 3, 2, 4])
        let mesh = try MeshIO.mesh(from: flat)
        #expect {
            try LoopCut.apply(mesh, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                              params: .init())
        } throws: {
            guard case .preconditionFailed(let m) = ($0 as? MeshOpError) else { return false }
            return m.contains("traverses quads only")
        }
    }

    /// A rung shared by three faces is non-manifold → refuse.
    @Test func rejectsNonManifoldRung() throws {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                     SIMD3(2, 0, 0), SIMD3(2, 1, 0)],
            faceVertexCounts: [4, 3, 3],
            faceVertexIndices: [0, 1, 2, 3, /*tri1*/ 2, 3, 4, /*tri2*/ 2, 3, 5])
        let mesh = try MeshIO.mesh(from: flat)
        #expect {
            try LoopCut.apply(mesh, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                              params: .init())
        } throws: {
            if case .nonManifoldRegion = ($0 as? MeshOpError) { return true }
            return false
        }
    }
}
