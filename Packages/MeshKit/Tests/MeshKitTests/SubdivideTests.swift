import Testing
import Foundation
import simd
@testable import MeshKit

/// Catmull-Clark subdivision: whole-mesh smoothing valid on every build
/// primitive (box/cylinder/cone/sphere closed, plane open).
@Suite("SubdivideCatmullClark")
struct SubdivideTests {

    // MARK: - Topology deltas on the five build primitives

    @Test func subdividesCubeToQuads() throws {
        let cube = Fixtures.cube() // V8 E12 F6, all quads
        let r = try SubdivideCatmullClark.apply(
            cube, selection: .faces(Set(cube.faceLoops.keys)), params: .init())
        // One level: ΔV = E + F = 18 → 26; ΔF = C − F = 24 − 6 = 18 → 24 quads;
        // ΔE = E + C = 12 + 24 = 36 → 48.
        #expect(r.mesh.vertexCount == 26)
        #expect(r.mesh.faceCount == 24)
        #expect(r.mesh.edgeCount == 48)
        #expect(r.mesh.faceLoops.values.allSatisfy { $0.count == 4 })
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        // Euler characteristic of a genus-0 closed solid stays 2.
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
        // resultSelection is the full new face set.
        #expect(r.resultSelection == .faces(Set(r.mesh.faceLoops.keys)))
        #expect(r.delta == TopologyDelta(vertices: 18, edges: 36, faces: 18))
    }

    @Test func subdividesAllClosedPrimitivesCleanly() throws {
        let closed: [HalfEdgeMesh] = [
            try Primitives.box(),
            try Primitives.cylinder(radialSegments: 6),
            try Primitives.cone(radialSegments: 6),
            try Primitives.uvSphere(rings: 4, segments: 6),
        ]
        for mesh in closed {
            let r = try SubdivideCatmullClark.apply(
                mesh, selection: .faces(Set(mesh.faceLoops.keys)), params: .init())
            #expect(r.mesh.faceLoops.values.allSatisfy { $0.count == 4 })
            #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
            #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
            // Smoothing shrinks a convex solid toward its limit surface.
            #expect(r.mesh.signedVolume > 0)
            #expect(r.mesh.signedVolume < mesh.signedVolume)
        }
    }

    @Test func subdividesOpenPlaneWithBoundaryRule() throws {
        let plane = try Primitives.plane(segmentsX: 2, segmentsZ: 2) // open surface
        let r = try SubdivideCatmullClark.apply(
            plane, selection: .faces(Set(plane.faceLoops.keys)), params: .init())
        #expect(r.mesh.faceLoops.values.allSatisfy { $0.count == 4 })
        // Boundaries are preserved (still an open surface), so this must pass
        // the boundary-permitting invariant suite but not the closed one.
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
        #expect(!r.mesh.boundaryEdges.isEmpty)
        // The plane stays flat: every vertex remains at y = 0.
        #expect(r.mesh.positions.values.allSatisfy { abs($0.y) < 1e-12 })
    }

    // MARK: - Multiple levels

    @Test func multipleLevelsCompound() throws {
        let cube = Fixtures.cube()
        let two = try SubdivideCatmullClark.apply(
            cube, selection: .faces(Set(cube.faceLoops.keys)), params: .init(levels: 2))
        // Level 1: 24 quads. Level 2: each quad → 4 → 96 quads.
        #expect(two.mesh.faceCount == 96)
        #expect(two.mesh.faceLoops.values.allSatisfy { $0.count == 4 })
        #expect(MeshInvariants.violations(in: two.mesh, allowBoundaries: false).isEmpty)
        #expect(MeshInvariants.eulerCharacteristic(of: two.mesh) == 2)
        // The reported delta is measured across all levels.
        #expect(two.delta.faces == 90)
    }

    // MARK: - Subset propagation

    @Test func carriesSubsetMembershipToChildQuads() throws {
        var cube = Fixtures.cube()
        let front = cube.faceOrder[0]
        cube.addFaceToSubset(front, subset: "panel")
        let r = try SubdivideCatmullClark.apply(
            cube, selection: .faces(Set(cube.faceLoops.keys)), params: .init())
        // A quad splits into exactly 4 children, all in the subset.
        #expect(r.mesh.subsets["panel"]?.count == 4)
        for f in r.mesh.subsets["panel"] ?? [] {
            #expect(r.mesh.faceLoops[f] != nil)
        }
    }

    // MARK: - Preconditions

    @Test func rejectsEmptySelection() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try SubdivideCatmullClark.apply(cube, selection: .faces([]), params: .init())
        }
        #expect(throws: MeshOpError.emptySelection) {
            try SubdivideCatmullClark.apply(cube, selection: .vertices([]), params: .init())
        }
    }

    @Test func rejectsNonFaceSelection() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try SubdivideCatmullClark.apply(
                cube, selection: .vertices(Set(cube.positions.keys)), params: .init())
        }
    }

    @Test func rejectsPartialFaceSelection() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try SubdivideCatmullClark.apply(
                cube, selection: .faces([cube.faceOrder[0]]), params: .init())
        }
    }

    @Test func rejectsZeroLevels() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try SubdivideCatmullClark.apply(
                cube, selection: .faces(Set(cube.faceLoops.keys)), params: .init(levels: 0))
        }
    }

    // MARK: - Purity

    @Test func doesNotMutateInput() throws {
        let cube = Fixtures.cube()
        let before = cube
        _ = try SubdivideCatmullClark.apply(
            cube, selection: .faces(Set(cube.faceLoops.keys)), params: .init())
        #expect(cube == before)
    }
}
