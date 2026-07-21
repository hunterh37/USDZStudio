import Testing
import Foundation
@testable import MeshKit

@Suite("HalfEdgeMesh core + invariants")
struct CoreTests {

    @Test func cubeTopology() {
        let cube = Fixtures.cube()
        #expect(cube.vertexCount == 8)
        #expect(cube.edgeCount == 12)
        #expect(cube.faceCount == 6)
        #expect(MeshInvariants.eulerCharacteristic(of: cube) == 2)
        #expect(MeshInvariants.violations(in: cube, allowBoundaries: false).isEmpty)
        #expect(abs(cube.signedVolume - 1.0) < 1e-12)
    }

    @Test func edgeSetMatchesCountAndKeys() {
        let cube = Fixtures.cube()
        // The undirected edge key set is the membership-only view used by
        // recipe edge selection; it must agree with edgeCount and with the
        // keys of the full edgeFaceMap.
        #expect(cube.edgeSet.count == cube.edgeCount)
        #expect(cube.edgeSet == Set(cube.edgeFaceMap.keys))
    }

    @Test func gridIsHealthyOpenSurface() {
        let grid = Fixtures.grid(4)
        #expect(MeshInvariants.violations(in: grid).isEmpty)
        #expect(MeshInvariants.eulerCharacteristic(of: grid) == 1) // disk
        #expect(grid.boundaryEdges.count == 16)
    }

    @Test func detectsBadWinding() {
        var flat = Fixtures.cubeFlat()
        flat.faceVertexIndices.replaceSubrange(0..<4, with: [0, 1, 2, 3]) // flipped bottom
        let mesh = try! MeshIO.mesh(from: flat)
        #expect(MeshInvariants.violations(in: mesh).contains { $0.rule == "winding" })
    }

    @Test func detectsNonManifoldEdge() {
        var mesh = Fixtures.cube()
        // Third face on an existing edge (verts 0-1).
        let extra = mesh.addVertex(SIMD3(0.5, -1, 0.5))
        mesh.addFace([VertexID(0), VertexID(1), extra])
        #expect(MeshInvariants.violations(in: mesh).contains { $0.rule == "manifold" })
    }

    @Test func detectsIsolatedVertex() {
        var mesh = Fixtures.cube()
        mesh.addVertex(SIMD3(9, 9, 9))
        #expect(MeshInvariants.violations(in: mesh).contains { $0.detail.contains("isolated") })
        mesh.pruneIsolatedVertices()
        #expect(MeshInvariants.violations(in: mesh).isEmpty)
    }

    @Test func detectsDegenerateFace() {
        var mesh = Fixtures.grid(1)
        let a = mesh.addVertex(SIMD3(5, 5, 0))
        let b = mesh.addVertex(SIMD3(6, 5, 0))
        let c = mesh.addVertex(SIMD3(7, 5, 0)) // collinear → zero area
        mesh.addFace([a, b, c])
        #expect(MeshInvariants.violations(in: mesh).contains { $0.rule == "degenerate" })
    }

    @Test func singleElementRemovalWrappers() {
        // The single-element `removeFace`/`removeVertex` delegate to the batch
        // primitives; ops delete in bulk, so exercise the scalar entry points
        // (public API) directly.
        var mesh = Fixtures.grid(2)
        let face = mesh.faceOrder[0]
        mesh.removeFace(face)
        #expect(mesh.faceLoops[face] == nil)
        #expect(!mesh.faceOrder.contains(face))
        mesh.pruneIsolatedVertices()
        let vertex = mesh.vertexOrder[0]
        mesh.removeVertex(vertex)
        #expect(mesh.positions[vertex] == nil)
        #expect(!mesh.vertexOrder.contains(vertex))
    }

    @Test func copyOnWriteSnapshotIsIndependent() {
        var a = Fixtures.cube()
        let snapshot = a
        a.setPosition(SIMD3(9, 9, 9), for: VertexID(0))
        #expect(snapshot.positions[VertexID(0)] == SIMD3(0, 0, 0))
        #expect(a != snapshot)
    }
}

@Suite("MeshIO round-trip")
struct MeshIOTests {

    @Test func losslessRoundTrip() throws {
        let flat = Fixtures.cubeFlat()
        let mesh = try MeshIO.mesh(from: flat)
        let back = MeshIO.flat(from: mesh)
        #expect(back == flat) // bit-faithful, CI invariant (spec §MeshIO)
    }

    @Test func roundTripPreservesUVsAndSubsets() throws {
        var flat = Fixtures.cubeFlat()
        flat.faceVaryingUVs = (0..<24).map { SIMD2(Double($0) / 24, 1 - Double($0) / 24) }
        flat.subsets = ["paint": [0, 2, 4], "chrome": [1]]
        let back = MeshIO.flat(from: try MeshIO.mesh(from: flat))
        #expect(back == flat)
    }

    @Test func refusesSkinnedMesh() {
        var flat = Fixtures.cubeFlat()
        flat.hasSkeletalBinding = true
        #expect(throws: MeshOpError.skinnedMeshUnsupported) { try MeshIO.mesh(from: flat) }
    }

    @Test func refusesMalformedCounts() {
        var flat = Fixtures.cubeFlat()
        flat.faceVertexCounts[0] = 5 // sum no longer matches indices
        #expect(throws: MeshOpError.self) { try MeshIO.mesh(from: flat) }
    }

    @Test func refusesOutOfRangeIndex() {
        var flat = Fixtures.cubeFlat()
        flat.faceVertexIndices[0] = 99
        #expect(throws: MeshOpError.self) { try MeshIO.mesh(from: flat) }
    }
}
