import Testing
import Foundation
@testable import MeshKit

@Suite("DeleteComponents")
struct DeleteTests {

    @Test func deleteFaceOpensCube() throws {
        let cube = Fixtures.cube()
        let r = try DeleteComponents.apply(cube, selection: .faces([Fixtures.cubeTop]))
        #expect(r.mesh.faceCount == 5)
        #expect(r.mesh.vertexCount == 8) // top verts still used by side faces
        #expect(r.mesh.boundaryEdges.count == 4)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func deleteVertexRemovesAdjacentFaces() throws {
        let cube = Fixtures.cube()
        let r = try DeleteComponents.apply(cube, selection: .vertices([VertexID(0)]))
        #expect(r.mesh.faceCount == 3) // corner vertex touches 3 faces
        #expect(r.mesh.positions[VertexID(0)] == nil)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func deleteEdgeRemovesBothFaces() throws {
        let cube = Fixtures.cube()
        let r = try DeleteComponents.apply(cube, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]))
        #expect(r.mesh.faceCount == 4)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func rejectsEmptyAndUnknown() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try DeleteComponents.apply(cube, selection: .faces([]))
        }
        #expect(throws: MeshOpError.self) {
            try DeleteComponents.apply(cube, selection: .faces([FaceID(99)]))
        }
    }
}

@Suite("MergeVertices")
struct MergeTests {

    @Test func mergeByDistanceWeldsSeam() throws {
        // Two 1×1 quads sharing an unwelded seam at x=1 (duplicate verts).
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                     SIMD3(1.000001, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1.000001, 1, 0)],
            faceVertexCounts: [4, 4],
            faceVertexIndices: [0, 1, 2, 3, 4, 5, 6, 7])
        let mesh = try MeshIO.mesh(from: flat)
        let r = try MergeVertices.apply(mesh, selection: .vertices(Set(mesh.positions.keys)),
                                        params: .byDistance(0.001))
        #expect(r.mesh.vertexCount == 6)
        #expect(r.mesh.faceCount == 2)
        #expect(r.mesh.edgeCount == 7) // welded shared edge
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func mergeToTargetCollapsesFace() throws {
        let grid = Fixtures.grid(1) // single quad
        let loop = grid.faceLoops[FaceID(0)]!
        let r = try MergeVertices.apply(grid, selection: .vertices([loop[0], loop[1]]),
                                        params: .toVertex(loop[0]))
        // Quad degenerates to a healthy triangle.
        #expect(r.mesh.faceCount == 1)
        #expect(r.mesh.faceLoops.values.first?.count == 3)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func refusesWhenNothingInRange() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try MergeVertices.apply(cube, selection: .vertices(Set(cube.positions.keys)),
                                    params: .byDistance(1e-6))
        }
    }

    @Test func refusesNonPositiveDistance() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try MergeVertices.apply(cube, selection: .vertices([VertexID(0)]),
                                    params: .byDistance(0))
        }
    }
}

@Suite("ExtrudeFaces")
struct ExtrudeTests {

    @Test func extrudeCubeTopMatchesAnalyticVolume() throws {
        let cube = Fixtures.cube()
        let h = 0.75
        let r = try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                       params: .init(distance: h))
        // Invariant 5: volume increases by exactly area × h (area = 1).
        #expect(abs(r.mesh.signedVolume - (1.0 + h)) < 1e-9)
        // Spec delta: boundaryV=4, boundaryE=4 → V+4, E+8, F+4.
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 8, faces: 4))
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    @Test func extrudeRegionSharesInteriorVerts() throws {
        // 2×2 grid, extrude two adjacent faces as one region.
        let grid = Fixtures.grid(2)
        let region: Set<FaceID> = [FaceID(0), FaceID(1)] // bottom row
        let before = grid
        let r = try ExtrudeFaces.apply(grid, selection: .faces(region),
                                       params: .init(distance: 1, direction: .axis(SIMD3(0, 0, 1))))
        let boundaryV = 6, boundaryE = 6
        #expect(r.delta == TopologyDelta(vertices: boundaryV,
                                         edges: boundaryE + boundaryV,
                                         faces: boundaryE))
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
        #expect(before == grid) // pure function: input untouched
    }

    @Test func negativeDistanceExtrudesInward() throws {
        let cube = Fixtures.cube()
        let r = try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                       params: .init(distance: -0.25))
        #expect(abs(r.mesh.signedVolume - 0.75) < 1e-9)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    @Test func refusesZeroDistanceAndZeroAxis() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                   params: .init(distance: 0))
        }
        #expect(throws: MeshOpError.self) {
            try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                   params: .init(distance: 1, direction: .axis(.zero)))
        }
    }
}

@Suite("InsetFaces")
struct InsetTests {

    @Test func insetCubeTopAnalyticArea() throws {
        let cube = Fixtures.cube()
        let t = 0.4
        let r = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: t))
        // Inner face area = (1−t)² × original area (invariant 5, closed form).
        guard case .faces(let inner) = r.resultSelection, let innerFace = inner.first else {
            Issue.record("no inner face returned"); return
        }
        #expect(abs(r.mesh.faceArea(innerFace) - pow(1 - t, 2)) < 1e-9)
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 8, faces: 4))
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        #expect(abs(r.mesh.signedVolume - 1.0) < 1e-9) // inset is volume-neutral
    }

    @Test func refusesOutOfRangeFraction() {
        let cube = Fixtures.cube()
        for bad in [0.0, 1.0, -0.5, 2.0] {
            #expect(throws: MeshOpError.self) {
                try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: bad))
            }
        }
    }

    @Test func depthOffsetsInnerFaceAlongNormalAndDeforms() throws {
        let cube = Fixtures.cube()
        let t = 0.4, depth = -0.3
        let flat = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                        params: .init(fraction: t))
        let deep = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                        params: .init(fraction: t, depth: depth))
        // Same topology delta — depth only moves vertices, never adds/removes.
        #expect(deep.delta == flat.delta)
        // In-plane inset is volume-neutral; a nonzero depth is not — pushing
        // the inner face inward removes volume, so the tool visibly deforms.
        #expect(abs(flat.mesh.signedVolume - 1.0) < 1e-9)
        #expect(deep.mesh.signedVolume < 1.0 - 1e-6)
        // The inner ring is offset by exactly `depth` along the +up normal.
        guard case .faces(let fi) = flat.resultSelection, let ff = fi.first,
              case .faces(let di) = deep.resultSelection, let df = di.first else {
            Issue.record("no inner face returned"); return
        }
        let dz = deep.mesh.faceCentroid(df).z - flat.mesh.faceCentroid(ff).z
        #expect(abs(dz - depth) < 1e-9)
        #expect(MeshInvariants.violations(in: deep.mesh, allowBoundaries: false).isEmpty)
    }

    @Test func depthDefaultsToZeroCoplanarInset() throws {
        let cube = Fixtures.cube()
        let a = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: 0.4))
        let b = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: 0.4, depth: 0))
        #expect(abs(a.mesh.signedVolume - b.mesh.signedVolume) < 1e-12)
    }
}

@Suite("FillHole")
struct FillHoleTests {

    @Test func fillsOpenBoxTop() throws {
        let box = Fixtures.openBox()
        let seed = box.boundaryEdges.first!
        let r = try FillHole.apply(box, selection: .edges([seed]))
        // n=4 loop: F += 2, E += 1, V += 0 (spec: F+=n−2, E+=n−3).
        #expect(r.delta == TopologyDelta(vertices: 0, edges: 1, faces: 2))
        #expect(r.mesh.boundaryEdges.isEmpty) // closed again
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        #expect(abs(r.mesh.signedVolume - 1.0) < 1e-9) // planar fill restores the cube
    }

    @Test func fillFromVertexSeed() throws {
        let box = Fixtures.openBox()
        let seedVert = box.boundaryEdges.first!.a
        let r = try FillHole.apply(box, selection: .vertices([seedVert]))
        #expect(r.mesh.boundaryEdges.isEmpty)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    @Test func refusesInteriorEdge() {
        let cube = Fixtures.cube()
        let interior = cube.edgeFaceMap.first { $0.value.count == 2 }!.key
        #expect(throws: MeshOpError.self) {
            try FillHole.apply(cube, selection: .edges([interior]))
        }
    }
}

@Suite("Round-trip after ops (invariant 8)")
struct RoundTripTests {

    @Test func opThenExportReimportPreservesTopology() throws {
        let cube = Fixtures.cube()
        let r = try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                       params: .init(distance: 0.5))
        let reimported = try MeshIO.mesh(from: MeshIO.flat(from: r.mesh))
        #expect(reimported.vertexCount == r.mesh.vertexCount)
        #expect(reimported.edgeCount == r.mesh.edgeCount)
        #expect(reimported.faceCount == r.mesh.faceCount)
        #expect(abs(reimported.signedVolume - r.mesh.signedVolume) < 1e-12)
    }

    @Test func snapshotUndoRestoresIdenticalMesh() throws {
        let cube = Fixtures.cube()
        let snapshot = cube // CoW snapshot = the undo record
        let hashBefore = cube.topologyHash
        _ = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                 params: .init(fraction: 0.3))
        #expect(snapshot.topologyHash == hashBefore) // hash-compared (spec)
        #expect(snapshot == cube)
    }
}

@Suite("BevelEdges")
struct BevelTests {

    /// Cube's top-front edge (verts 4,5): faces top + front, both endpoints
    /// face-valence 3 — the canonical bevel target.
    private var topFrontEdge: EdgeKey { EdgeKey(VertexID(4), VertexID(5)) }

    @Test func bevelCubeEdgeMatchesAnalyticVolume() throws {
        let cube = Fixtures.cube()
        let w = 0.25
        let r = try BevelEdges.apply(cube, selection: .edges([topFrontEdge]),
                                     params: .init(width: w))
        // Per-edge delta: V+2, E+3, F+1 (spec table, analytic).
        #expect(r.delta == TopologyDelta(vertices: 2, edges: 3, faces: 1))
        #expect(r.mesh.vertexCount == 10)
        #expect(r.mesh.edgeCount == 15)
        #expect(r.mesh.faceCount == 7)
        // Invariant 5: a right-triangle prism (legs w) is shaved off the edge.
        #expect(abs(r.mesh.signedVolume - (1 - w * w / 2)) < 1e-12)
        // Closed manifold stays closed and consistently wound.
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        // Result selection is the new bevel quad, with the analytic area w·√2 × 1.
        guard case .faces(let quads) = r.resultSelection, quads.count == 1 else {
            Issue.record("expected one new quad selected"); return
        }
        #expect(abs(r.mesh.faceArea(quads.first!) - w * 2.0.squareRoot()) < 1e-12)
        // Old edge endpoints are gone.
        #expect(r.mesh.positions[VertexID(4)] == nil)
        #expect(r.mesh.positions[VertexID(5)] == nil)
    }

    @Test func bevelTwoDisjointEdges() throws {
        let cube = Fixtures.cube()
        let w = 0.2
        let r = try BevelEdges.apply(
            cube,
            selection: .edges([EdgeKey(VertexID(4), VertexID(5)),
                               EdgeKey(VertexID(6), VertexID(7))]),
            params: .init(width: w))
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 6, faces: 2))
        #expect(abs(r.mesh.signedVolume - (1 - w * w)) < 1e-12)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    @Test func quadInheritsOnlySharedSubsets() throws {
        var cube = Fixtures.cube()
        let front = FaceID(2) // front face (import order)
        cube.addFaceToSubset(Fixtures.cubeTop, subset: "both")
        cube.addFaceToSubset(front, subset: "both")
        cube.addFaceToSubset(Fixtures.cubeTop, subset: "topOnly")
        let r = try BevelEdges.apply(cube, selection: .edges([topFrontEdge]),
                                     params: .init(width: 0.1))
        guard case .faces(let quads) = r.resultSelection, let quad = quads.first else {
            Issue.record("no quad"); return
        }
        #expect(r.mesh.subsets["both"]?.contains(quad) == true)
        #expect(r.mesh.subsets["topOnly"]?.contains(quad) != true)
    }

    @Test func refusesAdjacentSelectedEdges() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try BevelEdges.apply(cube,
                                 selection: .edges([EdgeKey(VertexID(4), VertexID(5)),
                                                    EdgeKey(VertexID(5), VertexID(6))]),
                                 params: .init(width: 0.1))
        }
    }

    @Test func refusesBoundaryEdge() {
        let box = Fixtures.openBox() // rim edges border a single face
        #expect(throws: MeshOpError.self) {
            try BevelEdges.apply(box, selection: .edges([EdgeKey(VertexID(4), VertexID(5))]),
                                 params: .init(width: 0.1))
        }
    }

    @Test func refusesHighValenceEndpoint() {
        // Interior grid edge: endpoints touch 4 faces — outside the strict v1 class.
        let grid = Fixtures.grid(3)
        let center = VertexID(5), right = VertexID(6) // interior verts of 3×3 grid
        #expect(throws: MeshOpError.self) {
            try BevelEdges.apply(grid, selection: .edges([EdgeKey(center, right)]),
                                 params: .init(width: 0.1))
        }
    }

    @Test func refusesOversizedAndNonPositiveWidth() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try BevelEdges.apply(cube, selection: .edges([topFrontEdge]),
                                 params: .init(width: 1.0)) // ≥ adjacent edge length
        }
        #expect(throws: MeshOpError.self) {
            try BevelEdges.apply(cube, selection: .edges([topFrontEdge]),
                                 params: .init(width: 0))
        }
    }

    @Test func refusesEmptyAndUnknownEdge() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try BevelEdges.apply(cube, selection: .edges([]), params: .init(width: 0.1))
        }
        #expect(throws: MeshOpError.self) {
            try BevelEdges.apply(cube, selection: .edges([EdgeKey(VertexID(90), VertexID(91))]),
                                 params: .init(width: 0.1))
        }
    }

    @Test func bevelRoundTripsAndLeavesOriginalUntouched() throws {
        let cube = Fixtures.cube()
        let hashBefore = cube.topologyHash
        let r = try BevelEdges.apply(cube, selection: .edges([topFrontEdge]),
                                     params: .init(width: 0.3))
        #expect(cube.topologyHash == hashBefore) // snapshot-undo record intact
        let reimported = try MeshIO.mesh(from: MeshIO.flat(from: r.mesh))
        #expect(reimported.vertexCount == r.mesh.vertexCount)
        #expect(reimported.edgeCount == r.mesh.edgeCount)
        #expect(reimported.faceCount == r.mesh.faceCount)
        #expect(abs(reimported.signedVolume - r.mesh.signedVolume) < 1e-12)
    }
}
