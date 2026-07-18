import Testing
import Foundation
import USDCore
import MeshKit
@testable import EditingKit

private func quadFlat() -> FlatMesh {
    FlatMesh(points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
             faceVertexCounts: [4],
             faceVertexIndices: [0, 1, 2, 3])
}

/// Unit cube, 6 quads, outward winding. V8 E12 F6, volume = 1.
private func cubeFlat() -> FlatMesh {
    FlatMesh(
        points: [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ],
        faceVertexCounts: [4, 4, 4, 4, 4, 4],
        faceVertexIndices: [
            0, 3, 2, 1,  4, 5, 6, 7,  0, 1, 5, 4,
            2, 3, 7, 6,  1, 2, 6, 5,  3, 0, 4, 7,
        ])
}

/// Cube with the top quad removed → open box with a 4-vertex boundary loop.
private func openBoxFlat() -> FlatMesh {
    var flat = cubeFlat()
    flat.faceVertexCounts.remove(at: 1)
    flat.faceVertexIndices.removeSubrange(4..<8)
    return flat
}

private func meshStage() -> InMemoryStage {
    let prim = Prim(path: PrimPath("/Root/Panel")!, typeName: "Mesh")
    let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [prim])
    return InMemoryStage(StageSnapshot(rootPrims: [root]))
}

@Suite("MeshEditSession")
struct MeshEditSessionTests {

    @Test func sessionAppliesOpAndCommits() throws {
        var session = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: quadFlat())
        let result = try ExtrudeFaces.apply(session.mesh, selection: .faces([FaceID(0)]),
                                            params: .init(distance: 0.5))
        session.record(result, journalEntry: "Extrude")
        #expect(session.isDirty)
        #expect(session.journal == ["Extrude"])

        let command = try #require(session.commitCommand())
        #expect(command.label == "Extrude (Panel)")
        #expect(command.after.points.count == 8)
        #expect(command.before == quadFlat())
    }

    @Test func sessionUndoRestoresWorkingMesh() throws {
        var session = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: quadFlat())
        let hashBefore = session.mesh.topologyHash
        let result = try InsetFaces.apply(session.mesh, selection: .faces([FaceID(0)]),
                                          params: .init(fraction: 0.25))
        session.record(result, journalEntry: "Inset")
        session.undo()
        #expect(session.mesh.topologyHash == hashBefore)
        #expect(!session.isDirty)
        #expect(session.commitCommand() == nil)
    }

    @Test func sessionRefusesSkinnedMesh() {
        var flat = quadFlat()
        flat.hasSkeletalBinding = true
        #expect(throws: MeshOpError.skinnedMeshUnsupported) {
            _ = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: flat)
        }
    }
}

/// Command/session-layer coverage for the four ops previously only tested at
/// the MeshKit op level: Bevel, FillHole, Merge, Delete. Each is exercised
/// through the undoable session wrapper (record → journal → undo/commit).
@Suite("MeshEditSession op coverage")
struct MeshEditSessionOpCoverageTests {

    @Test func bevelThroughSessionCommitsAndUndoes() throws {
        var session = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: cubeFlat())
        let hashBefore = session.mesh.topologyHash
        let w = 0.25
        let result = try BevelEdges.apply(session.mesh,
                                          selection: .edges([EdgeKey(VertexID(4), VertexID(5))]),
                                          params: .init(width: w))
        session.record(result, journalEntry: "Bevel")
        #expect(session.journal == ["Bevel"])
        // Analytic: a right-triangle prism (legs w) is shaved off the edge.
        #expect(abs(session.mesh.signedVolume - (1 - w * w / 2)) < 1e-12)
        #expect(MeshInvariants.violations(in: session.mesh, allowBoundaries: false).isEmpty)

        let command = try #require(session.commitCommand())
        #expect(command.label == "Bevel (Panel)")
        #expect(command.after.faceVertexCounts.count == 7) // 6 faces + bevel quad
        #expect(command.after.points.count == 10)          // 8 − 2 removed + 4 new

        session.undo()
        #expect(session.mesh.topologyHash == hashBefore)
        #expect(session.commitCommand() == nil)
    }

    @Test func fillHoleThroughSessionClosesMesh() throws {
        var session = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: openBoxFlat())
        #expect(!session.mesh.boundaryEdges.isEmpty)
        let seed = try #require(session.mesh.boundaryEdges.sorted(by: <).first)
        let result = try FillHole.apply(session.mesh, selection: .edges([seed]))
        session.record(result, journalEntry: "Fill Hole")
        // Hole closed: watertight, volume restored to the full unit cube.
        #expect(session.mesh.boundaryEdges.isEmpty)
        #expect(abs(session.mesh.signedVolume - 1) < 1e-12)
        #expect(MeshInvariants.violations(in: session.mesh, allowBoundaries: false).isEmpty)
        #expect(session.journal == ["Fill Hole"])

        let command = try #require(session.commitCommand())
        // 4-vertex loop fan-triangulates into 2 triangles: 5 quads + 2 tris.
        #expect(command.after.faceVertexCounts.sorted() == [3, 3, 4, 4, 4, 4, 4])
        #expect(command.after.points.count == 8) // no new vertices
    }

    @Test func mergeThroughSessionWeldsSeam() throws {
        // Two unit quads sharing an unwelded seam at x=1 (8 points, 2 faces).
        let flat = FlatMesh(
            points: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1, 1, 0),
            ],
            faceVertexCounts: [4, 4],
            faceVertexIndices: [0, 1, 2, 3, 4, 5, 6, 7])
        var session = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: flat)
        let result = try MergeVertices.apply(session.mesh,
                                             selection: .vertices(Set(session.mesh.positions.keys)),
                                             params: .byDistance(1e-6))
        session.record(result, journalEntry: "Merge")
        #expect(session.mesh.vertexCount == 6) // seam pair welded
        #expect(session.mesh.faceCount == 2)
        #expect(session.mesh.edgeCount == 7)
        #expect(MeshInvariants.violations(in: session.mesh).isEmpty)

        let command = try #require(session.commitCommand())
        #expect(command.after.points.count == 6)
        #expect(command.before == flat)
    }

    @Test func deleteThroughSessionUndoRestores() throws {
        var session = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: cubeFlat())
        let hashBefore = session.mesh.topologyHash
        let result = try DeleteComponents.apply(session.mesh, selection: .faces([FaceID(1)]))
        session.record(result, journalEntry: "Delete")
        #expect(session.mesh.faceCount == 5)
        #expect(session.mesh.boundaryEdges.count == 4) // deleting top opens one loop
        #expect(MeshInvariants.violations(in: session.mesh).isEmpty)

        session.undo()
        #expect(session.mesh.topologyHash == hashBefore)
        #expect(!session.isDirty)
    }

    @Test func multiOpJournalCommitsFinalMesh() throws {
        // Compose ops the way the editor does: fill → bevel on one journal.
        var session = try MeshEditSession(path: PrimPath("/Root/Panel")!, flat: openBoxFlat())
        let seed = try #require(session.mesh.boundaryEdges.sorted(by: <).first)
        session.record(try FillHole.apply(session.mesh, selection: .edges([seed])),
                       journalEntry: "Fill Hole")
        let edge = EdgeKey(VertexID(0), VertexID(1)) // bottom edge, valence-3 endpoints
        session.record(try BevelEdges.apply(session.mesh, selection: .edges([edge]),
                                            params: .init(width: 0.1)),
                       journalEntry: "Bevel")
        #expect(session.journal == ["Fill Hole", "Bevel"])
        #expect(MeshInvariants.violations(in: session.mesh, allowBoundaries: false).isEmpty)

        // The committed command round-trips through the stage.
        let stage = meshStage()
        let command = try #require(session.commitCommand())
        try command.execute(on: stage)
        let prim = try #require(stage.prim(at: PrimPath("/Root/Panel")!))
        guard case .intArray(let counts)? = prim.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("faceVertexCounts not authored"); return
        }
        #expect(counts == command.after.faceVertexCounts)
        try command.undo(on: stage)
        let restored = try #require(stage.prim(at: PrimPath("/Root/Panel")!))
        guard case .intArray(let restoredCounts)? = restored.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("faceVertexCounts missing after undo"); return
        }
        #expect(restoredCounts == openBoxFlat().faceVertexCounts)
    }
}

@Suite("MeshEditCommand")
struct MeshEditCommandTests {

    @Test func executeAuthorsArraysAndUndoRestores() throws {
        let stage = meshStage()
        let path = PrimPath("/Root/Panel")!
        var session = try MeshEditSession(path: path, flat: quadFlat())
        let result = try ExtrudeFaces.apply(session.mesh, selection: .faces([FaceID(0)]),
                                            params: .init(distance: 1))
        session.record(result, journalEntry: "Extrude")
        let command = try #require(session.commitCommand())

        try command.execute(on: stage)
        let prim = try #require(stage.prim(at: path))
        guard case .intArray(let counts)? = prim.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("faceVertexCounts not authored"); return
        }
        #expect(counts == command.after.faceVertexCounts)
        guard case .float3Array(let pts)? = prim.attribute(named: "points")?.value else {
            Issue.record("points not authored"); return
        }
        #expect(pts.count == command.after.points.count * 3)

        try command.undo(on: stage)
        let restored = try #require(stage.prim(at: path))
        guard case .intArray(let restoredCounts)? = restored.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("faceVertexCounts missing after undo"); return
        }
        #expect(restoredCounts == [4])
    }
}
