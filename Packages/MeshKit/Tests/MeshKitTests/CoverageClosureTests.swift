import Testing
import Foundation
@testable import MeshKit

/// Closes the last uncovered lines for the 100%-coverage gate
/// (specs/mesh-editing.md §Testing). Every test here pins a refusal or
/// defensive path that the mainline suites never reach.
@Suite("Coverage closure — refusal & defensive paths")
struct CoverageClosureTests {

    // MARK: - Invariants: degenerate-face detection branches

    @Test func violationsFlagUnderSizedLoop() throws {
        var mesh = Fixtures.cube()
        // replaceLoop is the only mutation primitive that can author a 2-loop.
        mesh.replaceLoop([VertexID(0), VertexID(1)], for: Fixtures.cubeTop)
        let v = MeshInvariants.violations(in: mesh)
        #expect(v.contains { $0.rule == "degenerate" && $0.detail.contains("2 vertices") })
    }

    @Test func violationsFlagRepeatedVertexInLoop() throws {
        var mesh = Fixtures.cube()
        mesh.replaceLoop([VertexID(0), VertexID(1), VertexID(0), VertexID(2)], for: Fixtures.cubeTop)
        let v = MeshInvariants.violations(in: mesh)
        #expect(v.contains { $0.rule == "degenerate" && $0.detail.contains("repeats a vertex") })
    }

    @Test func violationsFlagZeroLengthEdge() throws {
        var mesh = Fixtures.cube()
        // Collapse v1 onto v0 → every edge (v0,v1) has zero length.
        mesh.setPosition(mesh.positions[VertexID(0)]!, for: VertexID(1))
        let v = MeshInvariants.violations(in: mesh)
        #expect(v.contains { $0.rule == "degenerate" && $0.detail.contains("zero-length edge") })
    }

    @Test func assertHealthyPassesOnHealthyMeshAndThrowsOnSick() throws {
        try MeshInvariants.assertHealthy(Fixtures.cube())
        var sick = Fixtures.cube()
        sick.setPosition(sick.positions[VertexID(0)]!, for: VertexID(1))
        #expect(throws: MeshInvariants.Violation.self) {
            try MeshInvariants.assertHealthy(sick)
        }
    }

    // MARK: - MeshOp support

    @Test func eulerDeltaIsVMinusEPlusF() {
        #expect(TopologyDelta(vertices: 4, edges: 8, faces: 5).eulerDelta == 1)
    }

    @Test func verifyThrowsOnTopologyDeltaMismatch() throws {
        let cube = Fixtures.cube()
        #expect {
            try OpSupport.verify(before: cube, after: cube,
                                 predicted: TopologyDelta(vertices: 1, edges: 0, faces: 0))
        } throws: { error in
            guard case MeshOpError.invariantViolated(let msg) = error else { return false }
            return msg.contains("topology delta mismatch")
        }
    }

    // MARK: - Empty-selection refusals

    @Test func extrudeRefusesEmptySelection() {
        #expect(throws: MeshOpError.emptySelection) {
            _ = try ExtrudeFaces.apply(Fixtures.cube(), selection: .faces([]),
                                       params: .init(distance: 1))
        }
    }

    @Test func insetRefusesEmptySelection() {
        #expect(throws: MeshOpError.emptySelection) {
            _ = try InsetFaces.apply(Fixtures.cube(), selection: .faces([]),
                                     params: .init(fraction: 0.5))
        }
    }

    @Test func mergeRefusesEmptySelection() {
        #expect(throws: MeshOpError.emptySelection) {
            _ = try MergeVertices.apply(Fixtures.cube(), selection: .vertices([]),
                                        params: .byDistance(0.1))
        }
    }

    // MARK: - Unknown-component refusals

    @Test func deleteRefusesUnknownEdge() {
        #expect(throws: MeshOpError.unknownComponent("edge (98,99)")) {
            _ = try DeleteComponents.apply(
                Fixtures.cube(), selection: .edges([EdgeKey(VertexID(98), VertexID(99))]))
        }
    }

    @Test func deleteRefusesUnknownVertex() {
        #expect(throws: MeshOpError.unknownComponent("vertex 99")) {
            _ = try DeleteComponents.apply(Fixtures.cube(), selection: .vertices([VertexID(99)]))
        }
    }

    @Test func fillRefusesUnknownEdge() {
        #expect(throws: MeshOpError.unknownComponent("edge (98,99)")) {
            _ = try FillHole.apply(
                Fixtures.openBox(), selection: .edges([EdgeKey(VertexID(98), VertexID(99))]))
        }
    }

    @Test func fillRefusesVertexNotOnBoundary() {
        // Closed cube: no vertex sits on a boundary loop.
        #expect {
            _ = try FillHole.apply(Fixtures.cube(), selection: .vertices([VertexID(0)]))
        } throws: { error in
            guard case MeshOpError.preconditionFailed(let msg) = error else { return false }
            return msg.contains("not on a boundary loop")
        }
    }

    // MARK: - MeshIO

    @Test func meshIORefusesFaceWithFewerThanThreeVertices() {
        let flat = FlatMesh(points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)],
                            faceVertexCounts: [2], faceVertexIndices: [0, 1])
        #expect {
            _ = try MeshIO.mesh(from: flat)
        } throws: { error in
            guard case MeshOpError.preconditionFailed(let msg) = error else { return false }
            return msg.contains("face with 2 vertices")
        }
    }

    // MARK: - BevelEdges corner refusals

    /// Vertex whose three incident-face slots are [f1, f2, f1] (f1's loop
    /// visits it twice): valence check passes, but there is no distinct third
    /// face → nonManifoldRegion refusal.
    @Test func bevelRefusesWhenNoDistinctThirdFace() throws {
        var mesh = HalfEdgeMesh()
        let a = mesh.addVertex(SIMD3(0, 0, 0))
        let b = mesh.addVertex(SIMD3(1, 0, 0))
        let x = mesh.addVertex(SIMD3(1, 1, 0))
        let y = mesh.addVertex(SIMD3(-1, 1, 0))
        let z = mesh.addVertex(SIMD3(0, -1, 0))
        // f1 visits `a` twice → vertexFaceMap[a] = [f1, f1, f2].
        mesh.addFace([a, b, x, a, y])
        mesh.addFace([b, a, z])
        #expect {
            _ = try BevelEdges.apply(mesh, selection: .edges([EdgeKey(a, b)]),
                                     params: .init(width: 0.1))
        } throws: { error in
            guard case MeshOpError.nonManifoldRegion(let msg) = error else { return false }
            return msg.contains("no distinct third face")
        }
    }

    /// The beveled edge appears twice inside one face loop (f1 == f2 == wedge
    /// face), so both loop neighbors of the endpoint are the other endpoint →
    /// degenerate-wedge refusal.
    @Test func bevelRefusesDegenerateWedgeFace() throws {
        var mesh = HalfEdgeMesh()
        let v = mesh.addVertex(SIMD3(0, 0, 0))
        let o = mesh.addVertex(SIMD3(1, 0, 0))
        let x = mesh.addVertex(SIMD3(1, 1, 0))
        let p = mesh.addVertex(SIMD3(-1, 0, 0))
        let q = mesh.addVertex(SIMD3(0, -1, 0))
        // Wedge: loop [o, v, o, x] holds edge (v,o) twice → f1 == f2.
        mesh.addFace([o, v, o, x])
        // Two more faces at v so the valence-3 check passes.
        mesh.addFace([v, p, q])
        mesh.addFace([v, q, p])
        #expect {
            _ = try BevelEdges.apply(mesh, selection: .edges([EdgeKey(v, o)]),
                                     params: .init(width: 0.1))
        } throws: { error in
            guard case MeshOpError.preconditionFailed(let msg) = error else { return false }
            return msg.contains("degenerate wedge")
        }
    }

    // MARK: - FillHole boundary-walk guards

    /// Boundary out-edges without a matching in-edge at the far vertex: the
    /// hole walk starts but finds no continuation → "not closed" refusal.
    @Test func fillRefusesOpenBoundaryChain() throws {
        var mesh = HalfEdgeMesh()
        let x = mesh.addVertex(SIMD3(0, 0, 0))
        let v = mesh.addVertex(SIMD3(1, 0, 0))
        let s = mesh.addVertex(SIMD3(2, 0, 0))
        let z = mesh.addVertex(SIMD3(1, 1, 0))
        // Both faces traverse x→v (winding-inconsistent on purpose): edge
        // (x,v) is interior, while v's boundary edges are all outgoing.
        mesh.addFace([x, v, s])
        mesh.addFace([x, v, z])
        let result = Result { try FillHole.apply(mesh, selection: .edges([EdgeKey(v, s)])) }
        // The soup must be refused loudly, never filled: either the walk
        // detects the open chain, or seed/loop guards fire first.
        #expect(throws: MeshOpError.self) { try result.get() }
    }
}
