import Testing
import Foundation
@testable import MeshKit

/// High-value regression tests: each test targets a specific failure mode in
/// the v1 op set — attribute carry-through (spec invariant 6), analytic
/// geometry (invariant 5), determinism (redo contract), and topology deltas
/// on region selections (invariant 1).
@Suite("High-value regressions")
struct HighValueTests {

    // MARK: - Attribute integrity (spec invariant 6)

    /// Inset replaces the selected face with an inner face + side quads.
    /// GeomSubset (material) membership must carry to the replacement
    /// geometry — otherwise inset silently strips the face's material.
    @Test func insetCarriesSubsetMembership() throws {
        var cube = Fixtures.cube()
        cube.addFaceToSubset(Fixtures.cubeTop, subset: "paint")
        let r = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: 0.25))
        guard case .faces(let inner) = r.resultSelection else {
            Issue.record("expected face selection result"); return
        }
        let paint = r.mesh.subsets["paint"] ?? []
        // Inner face inherits the material…
        #expect(inner.isSubset(of: paint), "inner face lost subset membership")
        // …and so do the side quads (all 5 replacement faces).
        #expect(paint.count == 5, "expected inner + 4 side quads in subset, got \(paint.count)")
        // Untouched subsets untouched.
        #expect(!paint.contains(Fixtures.cubeTop))
    }

    /// Extrude keeps the cap face's ID (so its subset membership survives),
    /// but the new side quads must inherit the cap's subsets too.
    @Test func extrudeSideQuadsInheritCapSubset() throws {
        var cube = Fixtures.cube()
        cube.addFaceToSubset(Fixtures.cubeTop, subset: "chrome")
        let r = try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                       params: .init(distance: 0.5))
        let chrome = r.mesh.subsets["chrome"] ?? []
        #expect(chrome.contains(Fixtures.cubeTop), "cap lost subset membership")
        #expect(chrome.count == 5, "expected cap + 4 side quads in subset, got \(chrome.count)")
    }

    /// Deleting the only member of a subset must not leave an empty
    /// GeomSubset behind in the exported USD arrays.
    @Test func exportDropsEmptiedSubsets() throws {
        var flat = Fixtures.cubeFlat()
        flat.subsets = ["top": [1], "rest": [0, 2, 3, 4, 5]]
        let mesh = try MeshIO.mesh(from: flat)
        let r = try DeleteComponents.apply(mesh, selection: .faces([Fixtures.cubeTop]))
        let exported = MeshIO.flat(from: r.mesh)
        #expect(exported.subsets["top"] == nil, "emptied subset should not be exported")
        #expect(exported.subsets["rest"]?.count == 5)
    }

    /// Bit-faithful round trip with UVs + subsets on an untouched mesh
    /// (CI invariant from the spec).
    @Test func roundTripBitFaithfulWithAllChannels() throws {
        var flat = Fixtures.cubeFlat()
        flat.faceVaryingUVs = (0..<24).map { SIMD2(Double($0) / 24, Double($0 % 4) / 4) }
        flat.subsets = ["a": [0, 5], "b": [2]]
        let back = MeshIO.flat(from: try MeshIO.mesh(from: flat))
        #expect(back == flat)
    }

    // MARK: - Determinism (redo contract)

    /// FillHole seeded by a *vertex* must resolve the same boundary edge every
    /// time — redo re-applies deterministically, so two applications on the
    /// same mesh must produce identical topology (same fan apex).
    @Test func fillHoleByVertexIsDeterministic() throws {
        let box = Fixtures.openBox()
        // The boundary vertex 4 touches two boundary edges; the seed choice
        // must not depend on dictionary iteration order.
        let a = try FillHole.apply(box, selection: .vertices([VertexID(4)]))
        for _ in 0..<20 {
            let b = try FillHole.apply(box, selection: .vertices([VertexID(4)]))
            #expect(MeshIO.flat(from: a.mesh) == MeshIO.flat(from: b.mesh),
                    "fill-hole triangulation is nondeterministic")
        }
    }

    /// Same determinism requirement when seeding by edge set.
    @Test func fillHoleByEdgeSetIsDeterministic() throws {
        let box = Fixtures.openBox()
        let edges: Set<EdgeKey> = [EdgeKey(VertexID(4), VertexID(5)),
                                   EdgeKey(VertexID(6), VertexID(7))]
        let a = try FillHole.apply(box, selection: .edges(edges))
        for _ in 0..<20 {
            let b = try FillHole.apply(box, selection: .edges(edges))
            #expect(MeshIO.flat(from: a.mesh) == MeshIO.flat(from: b.mesh))
        }
    }

    // MARK: - Analytic geometry (spec invariant 5)

    /// Cube face extruded by h: volume increases by exactly area × h.
    @Test func extrudeVolumeIsAnalytic() throws {
        let cube = Fixtures.cube()
        let h = 0.75
        let r = try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                       params: .init(distance: h))
        #expect(abs(r.mesh.signedVolume - (1.0 + 1.0 * h)) < 1e-9)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    /// Negative distance extrudes inward: volume shrinks by area × |h| and the
    /// mesh stays manifold with consistent winding.
    @Test func negativeExtrudeShrinksVolume() throws {
        let cube = Fixtures.cube()
        let r = try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                       params: .init(distance: -0.25))
        #expect(abs(r.mesh.signedVolume - 0.75) < 1e-9)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    /// Inset by fraction t: inner face area = (1−t)² × original (similar polygon).
    @Test func insetInnerFaceAreaIsAnalytic() throws {
        let cube = Fixtures.cube()
        let t = 0.3
        let r = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: t))
        guard case .faces(let inner) = r.resultSelection, let f = inner.first else {
            Issue.record("expected inner face"); return
        }
        #expect(abs(r.mesh.faceArea(f) - (1 - t) * (1 - t)) < 1e-9)
        #expect(abs(r.mesh.signedVolume - 1.0) < 1e-9) // coplanar inset: volume unchanged
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    /// Filling the open box's hole restores the exact unit-cube volume and a
    /// closed manifold — proving the fan's winding matches its neighbors.
    @Test func fillHoleRestoresClosedVolume() throws {
        let box = Fixtures.openBox()
        let r = try FillHole.apply(box, selection: .edges([EdgeKey(VertexID(4), VertexID(5))]))
        #expect(r.delta == TopologyDelta(vertices: 0, edges: 1, faces: 2))
        #expect(abs(r.mesh.signedVolume - 1.0) < 1e-9)
        #expect(r.mesh.boundaryEdges.isEmpty)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    // MARK: - Region topology (spec invariant 1)

    /// Two adjacent cube faces extruded as one region: the shared edge is
    /// interior, so delta is V+6 E+12 F+6 and Euler characteristic is preserved.
    @Test func extrudeAdjacentRegionSharedEdgeAccounting() throws {
        let cube = Fixtures.cube()
        let region: Set<FaceID> = [Fixtures.cubeTop, FaceID(4)] // top + right
        let r = try ExtrudeFaces.apply(cube, selection: .faces(region),
                                       params: .init(distance: 0.5)) // averaged normal ≈ (1,0,1)/√2
        #expect(r.delta == TopologyDelta(vertices: 6, edges: 12, faces: 6))
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    /// Extruding along an axis parallel to a region-boundary edge would sweep
    /// zero-area side quads — must fail as an actionable *precondition*, not
    /// a post-op invariant violation (spec: fail loudly with a diagnostic).
    @Test func extrudeRejectsAxisParallelToBoundaryEdge() throws {
        let cube = Fixtures.cube()
        let region: Set<FaceID> = [Fixtures.cubeTop, FaceID(4)] // top + right
        // z-axis is parallel to the right face's vertical boundary edges.
        #expect {
            try ExtrudeFaces.apply(cube, selection: .faces(region),
                                   params: .init(distance: 0.5, direction: .axis(SIMD3(0, 0, 1))))
        } throws: { error in
            if case MeshOpError.preconditionFailed = error { return true }
            return false
        }
    }

    /// Extruding *every* face of a closed mesh has no boundary: the whole
    /// solid translates. Zero topology delta, volume preserved.
    @Test func extrudeWholeClosedMeshTranslates() throws {
        let cube = Fixtures.cube()
        let r = try ExtrudeFaces.apply(cube, selection: .faces(Set(cube.faceOrder)),
                                       params: .init(distance: 2, direction: .axis(SIMD3(1, 0, 0))))
        #expect(r.delta == TopologyDelta(vertices: 0, edges: 0, faces: 0))
        #expect(abs(r.mesh.signedVolume - 1.0) < 1e-9)
        #expect(abs(r.mesh.faceCentroid(Fixtures.cubeTop).x - cube.faceCentroid(Fixtures.cubeTop).x - 2) < 1e-9)
    }

    /// Interior face of an open grid: extrusion must respect the surface's
    /// existing boundary and stay manifold.
    @Test func extrudeGridInteriorFace() throws {
        let grid = Fixtures.grid(3)
        let center = grid.faceOrder[4] // middle face of 3×3
        let r = try ExtrudeFaces.apply(grid, selection: .faces([center]),
                                       params: .init(distance: 1))
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 8, faces: 4))
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    /// Inset → extrude the inner face: the classic bevel-ish compound.
    /// Composition must keep every invariant.
    @Test func insetThenExtrudeCompose() throws {
        let cube = Fixtures.cube()
        let i = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: 0.4))
        let e = try ExtrudeFaces.apply(i.mesh, selection: i.resultSelection,
                                       params: .init(distance: 0.5))
        #expect(MeshInvariants.eulerCharacteristic(of: e.mesh) == 2)
        #expect(MeshInvariants.violations(in: e.mesh, allowBoundaries: false).isEmpty)
        let capArea = 0.6 * 0.6
        #expect(abs(e.mesh.signedVolume - (1.0 + capArea * 0.5)) < 1e-9)
    }

    // MARK: - Merge semantics

    /// Collapsing one cube edge (toVertex): the two adjacent quads become
    /// triangles; everything stays manifold with consistent winding.
    @Test func mergeCollapsesCubeEdgeToTriangles() throws {
        let cube = Fixtures.cube()
        let r = try MergeVertices.apply(cube, selection: .vertices([VertexID(0), VertexID(1)]),
                                        params: .toVertex(VertexID(1)))
        #expect(r.mesh.vertexCount == 7)
        #expect(r.mesh.faceCount == 6)
        let triCount = r.mesh.faceLoops.values.filter { $0.count == 3 }.count
        #expect(triCount == 2, "the two faces sharing the collapsed edge should be triangles")
        // Target keeps its exact position.
        #expect(r.mesh.positions[VertexID(1)] == SIMD3<Double>(1, 0, 0))
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    /// byDistance welds a cluster at its centroid and is transitive:
    /// A–B and B–C within threshold merge all three even when A–C is not.
    @Test func mergeByDistanceIsTransitiveAndCentroidal() throws {
        var mesh = HalfEdgeMesh()
        let a = mesh.addVertex(SIMD3(0, 0, 0))
        let b = mesh.addVertex(SIMD3(0.09, 0, 0))
        let c = mesh.addVertex(SIMD3(0.18, 0, 0)) // |a−c| > 0.1 but chained via b
        let d = mesh.addVertex(SIMD3(0, 5, 0))
        let e = mesh.addVertex(SIMD3(3, 5, 0))
        mesh.addFace([a, e, d])
        mesh.addFace([b, e, a])
        mesh.addFace([c, e, b])
        let r = try MergeVertices.apply(mesh, selection: .vertices([a, b, c]),
                                        params: .byDistance(0.1))
        #expect(r.mesh.vertexCount == 3)
        #expect(r.mesh.faceCount == 1)
        guard case .vertices(let survivors) = r.resultSelection, let rep = survivors.first else {
            Issue.record("expected surviving representative"); return
        }
        let p = r.mesh.positions[rep]!
        #expect(abs(p.x - 0.09) < 1e-12 && p.y == 0, "cluster should weld at its centroid")
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    /// A weld that would create a non-manifold edge must throw a typed error,
    /// never return garbage (spec: no third outcome).
    @Test func mergeRejectsResultingNonManifold() throws {
        // Two triangle "pages" sharing edge (s,t) plus a third page whose far
        // vertex gets welded onto t's neighbor — drives edge (s,t) past 2 faces.
        var mesh = HalfEdgeMesh()
        let s = mesh.addVertex(SIMD3(0, 0, 0))
        let t = mesh.addVertex(SIMD3(1, 0, 0))
        let p1 = mesh.addVertex(SIMD3(0.5, 1, 0))
        let p2 = mesh.addVertex(SIMD3(0.5, -1, 0))
        let p3 = mesh.addVertex(SIMD3(0.5, 0, 1)) // will weld onto p1
        mesh.addFace([s, t, p1])
        mesh.addFace([t, s, p2])
        mesh.addFace([s, t, p3]) // same winding as face 1 → after weld: 3 faces on (s,t)
        #expect(throws: MeshOpError.self) {
            try MergeVertices.apply(mesh, selection: .vertices([p1, p3]),
                                    params: .toVertex(p1))
        }
    }

    /// Threshold ≤ 0 and out-of-range verts are loud precondition failures.
    @Test func mergePreconditionDiagnostics() throws {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.preconditionFailed("merge distance must be > 0")) {
            try MergeVertices.apply(cube, selection: .vertices([VertexID(0), VertexID(1)]),
                                    params: .byDistance(0))
        }
        #expect(throws: MeshOpError.preconditionFailed("no vertices within merge range")) {
            try MergeVertices.apply(cube, selection: .vertices([VertexID(0), VertexID(6)]),
                                    params: .byDistance(1e-6)) // opposite corners
        }
        #expect(throws: MeshOpError.unknownComponent("target vertex 99")) {
            try MergeVertices.apply(cube, selection: .vertices([VertexID(0)]),
                                    params: .toVertex(VertexID(99)))
        }
    }

    // MARK: - Delete edge cases

    /// Deleting every face empties the mesh completely (isolation rule:
    /// orphaned vertices are pruned, never left dangling).
    @Test func deleteAllFacesEmptiesMesh() throws {
        let cube = Fixtures.cube()
        let r = try DeleteComponents.apply(cube, selection: .faces(Set(cube.faceOrder)))
        #expect(r.mesh.faceCount == 0)
        #expect(r.mesh.vertexCount == 0)
        #expect(r.mesh.edgeCount == 0)
        #expect(MeshIO.flat(from: r.mesh).points.isEmpty)
    }

    /// Vertex IDs are never recycled: delete then add must mint a fresh ID
    /// (stable-ID contract that selection persistence and undo rely on).
    @Test func idsAreNeverRecycled() throws {
        var mesh = Fixtures.cube()
        let oldIDs = Set(mesh.vertexOrder)
        let r = try DeleteComponents.apply(mesh, selection: .vertices([VertexID(0)]))
        mesh = r.mesh
        let fresh = mesh.addVertex(SIMD3(9, 9, 9))
        #expect(!oldIDs.contains(fresh), "recycled VertexID would corrupt undo selections")
    }

    // MARK: - Round trip after edits (spec invariant 8)

    /// Op → export → reimport → identical topology counts and geometry.
    @Test func editedMeshSurvivesRoundTrip() throws {
        let cube = Fixtures.cube()
        let r = try ExtrudeFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                       params: .init(distance: 1))
        let back = try MeshIO.mesh(from: MeshIO.flat(from: r.mesh))
        #expect(back.vertexCount == r.mesh.vertexCount)
        #expect(back.edgeCount == r.mesh.edgeCount)
        #expect(back.faceCount == r.mesh.faceCount)
        #expect(abs(back.signedVolume - r.mesh.signedVolume) < 1e-12)
        #expect(MeshInvariants.violations(in: back, allowBoundaries: false).isEmpty)
    }

    /// topologyHash: equal for value copies, different after any edit —
    /// it's the undo-verification primitive.
    @Test func topologyHashDetectsEdits() throws {
        let cube = Fixtures.cube()
        let copy = cube
        #expect(cube.topologyHash == copy.topologyHash)
        var moved = cube
        moved.setPosition(SIMD3(0, 0, 0.001), for: VertexID(0))
        #expect(cube.topologyHash != moved.topologyHash)
        let r = try InsetFaces.apply(cube, selection: .faces([Fixtures.cubeTop]),
                                     params: .init(fraction: 0.5))
        #expect(cube.topologyHash != r.mesh.topologyHash)
    }
}
