import Testing
import Foundation
@testable import MeshKit

@Suite("Decimate — QEM edge-collapse")
struct DecimateTests {

    // MARK: Fixtures

    /// Dense closed manifold: Catmull-Clark-subdivided cube (96 tris after the
    /// op's internal fan-triangulation), no boundary, no UV seams → interior is
    /// freely collapsible.
    private func denseCube(levels: Int = 2) throws -> HalfEdgeMesh {
        let cube = Fixtures.cube()
        return try SubdivideCatmullClark.apply(
            cube, selection: .faces(Set(cube.faceOrder)), params: .init(levels: levels)).mesh
    }

    private func all(_ m: HalfEdgeMesh) -> ComponentSelection { .faces(Set(m.faceOrder)) }

    // MARK: Happy paths

    @Test func reducesClosedMeshAndStaysManifoldAndClosed() throws {
        let mesh = try denseCube()
        let before = mesh.faceCount * 0 + trianglesIn(mesh)
        let r = try Decimate.apply(mesh, selection: all(mesh),
                                   params: .init(target: .ratio(0.5)))
        #expect(r.mesh.faceCount < before)                 // reduced
        #expect(r.mesh.boundaryEdges.isEmpty)              // still closed
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        // Every output face is a triangle.
        #expect(r.mesh.faceLoops.values.allSatisfy { $0.count == 3 })
        // Euler characteristic of a closed genus-0 surface stays 2.
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
    }

    @Test func volumeDriftBoundedOnClosedMesh() throws {
        let mesh = try denseCube()
        let v0 = abs(mesh.signedVolume)
        let r = try Decimate.apply(mesh, selection: all(mesh),
                                   params: .init(target: .ratio(0.4)))
        let v1 = abs(r.mesh.signedVolume)
        // QEM preserves shape well; drift must stay well under 25%.
        #expect(abs(v1 - v0) / v0 < 0.25)
    }

    @Test func triangleCountTargetIsRespectedOrBestEffort() throws {
        let mesh = try denseCube()
        let r = try Decimate.apply(mesh, selection: all(mesh),
                                   params: .init(target: .triangleCount(40)))
        // Never *below* target; may stop above it when collapses get blocked.
        #expect(r.mesh.faceCount >= 40)
        #expect(r.mesh.faceCount < trianglesIn(mesh))
    }

    @Test func monotonicReductionAcrossTighterTargets() throws {
        let mesh = try denseCube()
        let loose = try Decimate.apply(mesh, selection: all(mesh),
                                       params: .init(target: .ratio(0.8))).mesh.faceCount
        let tight = try Decimate.apply(mesh, selection: all(mesh),
                                       params: .init(target: .ratio(0.3))).mesh.faceCount
        #expect(tight <= loose)
    }

    @Test func preservesBoundaryLoopExactly() throws {
        let grid = Fixtures.grid(6)
        let boundaryVerts = boundaryVertexPositions(grid)
        let r = try Decimate.apply(grid, selection: all(grid),
                                   params: .init(target: .triangleCount(2)))
        // Boundary ring cannot collapse: same perimeter vertices, same positions.
        let outBoundary = boundaryVertexPositions(r.mesh)
        #expect(outBoundary == boundaryVerts)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func disablingBoundaryPreservationAllowsDeeperReduction() throws {
        let grid = Fixtures.grid(6)
        let kept = try Decimate.apply(grid, selection: all(grid),
                                      params: .init(target: .triangleCount(2),
                                                    preserveBoundary: true)).mesh.faceCount
        let free = try Decimate.apply(grid, selection: all(grid),
                                      params: .init(target: .triangleCount(2),
                                                    preserveBoundary: false)).mesh.faceCount
        #expect(free <= kept)
    }

    @Test func maxErrorCapStopsCollapsesEarly() throws {
        let mesh = try denseCube()
        // A tiny cap forbids essentially every collapse (each removes real volume).
        let r = try Decimate.apply(mesh, selection: all(mesh),
                                   params: .init(target: .triangleCount(1), maxError: 1e-12))
        // Almost nothing collapses → count stays near the triangulated original.
        #expect(r.mesh.faceCount >= trianglesIn(mesh) - 2)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
    }

    @Test func ratioOfOneJustTriangulates() throws {
        let cube = Fixtures.cube()             // 6 quads
        let r = try Decimate.apply(cube, selection: all(cube),
                                   params: .init(target: .ratio(1.0)))
        #expect(r.mesh.faceCount == 12)        // 6 quads → 12 triangles, no collapse
        #expect(r.mesh.faceLoops.values.allSatisfy { $0.count == 3 })
        #expect(r.mesh.boundaryEdges.isEmpty)
    }

    // MARK: Attribute preservation

    @Test func carriesSubsetsThroughDecimation() throws {
        var mesh = try denseCube()
        // Tag half the faces into a subset.
        let tagged = Set(mesh.faceOrder.prefix(mesh.faceCount / 2))
        for f in tagged { mesh.addFaceToSubset(f, subset: "mat") }
        let r = try Decimate.apply(mesh, selection: all(mesh),
                                   params: .init(target: .ratio(0.5)))
        // Subset survives and only references live faces.
        let members = r.mesh.subsets["mat"] ?? []
        #expect(!members.isEmpty)
        #expect(members.isSubset(of: Set(r.mesh.faceOrder)))
    }

    @Test func pinsUVSeamsAndCarriesUVChannel() throws {
        // A quad strip with a UV seam down the middle column: the shared vertices
        // carry different UVs on the left vs right face → seam → pinned.
        let mesh = seamStrip()
        let seamVerts = seamVertexPositions(mesh)
        let r = try Decimate.apply(mesh, selection: all(mesh),
                                   params: .init(target: .triangleCount(1),
                                                 preserveUVSeams: true))
        // UV channel is re-emitted.
        #expect(!r.mesh.faceCornerUVs.isEmpty)
        // Seam vertices are frozen (unchanged positions present in output).
        let outVerts = Set(r.mesh.positions.values.map { key($0) })
        for p in seamVerts { #expect(outVerts.contains(p)) }
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func seamPreservationCanBeDisabled() throws {
        let mesh = seamStrip()
        let pinned = try Decimate.apply(mesh, selection: all(mesh),
                                        params: .init(target: .triangleCount(1),
                                                      preserveUVSeams: true)).mesh.faceCount
        let free = try Decimate.apply(mesh, selection: all(mesh),
                                      params: .init(target: .triangleCount(1),
                                                    preserveUVSeams: false)).mesh.faceCount
        #expect(free <= pinned)
    }

    // MARK: Determinism & purity

    @Test func isDeterministic() throws {
        let mesh = try denseCube()
        let a = try Decimate.apply(mesh, selection: all(mesh), params: .init(target: .ratio(0.35))).mesh
        let b = try Decimate.apply(mesh, selection: all(mesh), params: .init(target: .ratio(0.35))).mesh
        #expect(a == b)
    }

    @Test func inputIsNeverMutated() throws {
        let mesh = try denseCube()
        let snapshot = mesh
        _ = try Decimate.apply(mesh, selection: all(mesh), params: .init(target: .ratio(0.2)))
        #expect(mesh == snapshot)
    }

    @Test func resultSelectionIsAllOutputFaces() throws {
        let mesh = try denseCube()
        let r = try Decimate.apply(mesh, selection: all(mesh), params: .init(target: .ratio(0.5)))
        guard case .faces(let sel) = r.resultSelection else { Issue.record("faces"); return }
        #expect(sel == Set(r.mesh.faceOrder))
    }

    @Test func roundTripsThroughFlatArrays() throws {
        let mesh = try denseCube()
        let r = try Decimate.apply(mesh, selection: all(mesh), params: .init(target: .ratio(0.4)))
        let re = try MeshIO.mesh(from: MeshIO.flat(from: r.mesh))
        #expect(re.faceCount == r.mesh.faceCount)
        #expect(re.edgeCount == r.mesh.edgeCount)
    }

    // MARK: Refusals

    @Test func refusesNonFaceSelection() throws {
        let mesh = try denseCube()
        #expect(throws: MeshOpError.emptySelection) {
            try Decimate.apply(mesh, selection: .vertices([]), params: .init(target: .ratio(0.5)))
        }
    }

    @Test func refusesEmptySelection() throws {
        let mesh = try denseCube()
        #expect(throws: MeshOpError.emptySelection) {
            try Decimate.apply(mesh, selection: .faces([]), params: .init(target: .ratio(0.5)))
        }
    }

    @Test func refusesPartialSelection() throws {
        let mesh = try denseCube()
        #expect(throws: (any Error).self) {
            try Decimate.apply(mesh, selection: .faces([mesh.faceOrder[0]]),
                               params: .init(target: .ratio(0.5)))
        }
    }

    @Test func refusesRatioOutOfRange() throws {
        let mesh = try denseCube()
        #expect(throws: (any Error).self) {
            try Decimate.apply(mesh, selection: all(mesh), params: .init(target: .ratio(0)))
        }
        #expect(throws: (any Error).self) {
            try Decimate.apply(mesh, selection: all(mesh), params: .init(target: .ratio(1.5)))
        }
    }

    @Test func refusesNegativeMaxError() throws {
        let mesh = try denseCube()
        #expect(throws: (any Error).self) {
            try Decimate.apply(mesh, selection: all(mesh),
                               params: .init(target: .ratio(0.5), maxError: -1))
        }
    }

    @Test func refusesNonManifoldInput() {
        // Three triangles fanning around one shared edge → non-manifold.
        var m = HalfEdgeMesh()
        let a = m.addVertex(SIMD3(0, 0, 0)), b = m.addVertex(SIMD3(1, 0, 0))
        let c = m.addVertex(SIMD3(0, 1, 0)), d = m.addVertex(SIMD3(0, 0, 1))
        let e = m.addVertex(SIMD3(0, -1, 0))
        m.addFace([a, b, c]); m.addFace([a, b, d]); m.addFace([a, b, e])
        #expect(throws: (any Error).self) {
            try Decimate.apply(m, selection: .faces(Set(m.faceOrder)),
                               params: .init(target: .ratio(0.5)))
        }
    }

    @Test func triangleCountBelowOneClampsToOne() throws {
        let grid = Fixtures.grid(3)
        // Negative/zero target clamps to 1; best-effort stops when blocked.
        let r = try Decimate.apply(grid, selection: all(grid),
                                   params: .init(target: .triangleCount(-5)))
        #expect(r.mesh.faceCount >= 1)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    // MARK: Quadric unit tests

    @Test func quadricErrorIsZeroOnItsPlane() {
        // Plane z = 0 (n = +z, d = 0). Points on the plane have zero error.
        let q = Quadric.plane(SIMD3(0, 0, 1), 0)
        #expect(q.error(SIMD3(3, -4, 0)) == 0)
        // A point one unit off the plane has error 1² = 1.
        #expect(abs(q.error(SIMD3(0, 0, 1)) - 1) < 1e-12)
    }

    @Test func quadricSumAccumulatesPlanes() {
        let qx = Quadric.plane(SIMD3(1, 0, 0), 0)   // x = 0
        let qy = Quadric.plane(SIMD3(0, 1, 0), 0)   // y = 0
        let q = qx + qy
        // Distance² to both planes from (1,1,0) is 1 + 1 = 2.
        #expect(abs(q.error(SIMD3(1, 1, 0)) - 2) < 1e-12)
        // Optimal position is the intersection line's nearest point → origin in xy.
        let opt = q.optimalPosition()
        #expect(opt == nil || abs(opt!.x) < 1e-6)   // z is free → singular block
    }

    @Test func quadricOptimalSolvesThreePlanes() {
        // Three axis planes offset to intersect at (2, 3, 4).
        let q = Quadric.plane(SIMD3(1, 0, 0), -2)
            + Quadric.plane(SIMD3(0, 1, 0), -3)
            + Quadric.plane(SIMD3(0, 0, 1), -4)
        let opt = q.optimalPosition()
        #expect(opt != nil)
        #expect(simd_length(opt! - SIMD3(2, 3, 4)) < 1e-9)
    }

    @Test func quadricScaleMultipliesError() {
        let q = Quadric.plane(SIMD3(0, 0, 1), 0) * 4
        #expect(abs(q.error(SIMD3(0, 0, 1)) - 4) < 1e-12)
    }

    // MARK: Helpers

    private func trianglesIn(_ m: HalfEdgeMesh) -> Int {
        m.faceOrder.reduce(0) { $0 + (m.faceLoops[$1]!.count - 2) }
    }

    private func boundaryVertexPositions(_ m: HalfEdgeMesh) -> Set<[Int]> {
        var verts = Set<VertexID>()
        for e in m.boundaryEdges { verts.insert(e.a); verts.insert(e.b) }
        return Set(verts.map { key(m.positions[$0]!) })
    }

    private func seamVertexPositions(_ m: HalfEdgeMesh) -> Set<[Int]> {
        // The two middle-column vertices at x = 1.
        Set(m.positions.values.filter { abs($0.x - 1) < 1e-9 }.map { key($0) })
    }

    private func key(_ p: SIMD3<Double>) -> [Int] {
        [Int((p.x * 1e6).rounded()), Int((p.y * 1e6).rounded()), Int((p.z * 1e6).rounded())]
    }

    /// 2×1 quad strip (three columns) with a UV discontinuity on the middle
    /// column: left face maps it to u = 1, right face to u = 0.
    private func seamStrip() -> HalfEdgeMesh {
        var m = HalfEdgeMesh()
        let v = (0..<6).map { i -> VertexID in
            m.addVertex(SIMD3(Double(i % 3), Double(i / 3), 0))
        }
        // Faces: columns 0-1 and 1-2.
        m.addFace([v[0], v[1], v[4], v[3]],
                  uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        m.addFace([v[1], v[2], v[5], v[4]],
                  uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        return m
    }
}
