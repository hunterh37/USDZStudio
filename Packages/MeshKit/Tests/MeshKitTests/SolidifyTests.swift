import Testing
import Foundation
@testable import MeshKit

@Suite("Solidify")
struct SolidifyTests {

    /// Single UV-tagged quad in the z = 0 plane, used for the subset/UV paths.
    private func uvQuad() -> HalfEdgeMesh {
        var m = HalfEdgeMesh()
        let a = m.addVertex(SIMD3(0, 0, 0)), b = m.addVertex(SIMD3(1, 0, 0))
        let c = m.addVertex(SIMD3(1, 1, 0)), d = m.addVertex(SIMD3(0, 1, 0))
        let f = m.addFace([a, b, c, d],
                          uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        m.addFaceToSubset(f, subset: "mat")
        return m
    }

    /// Non-manifold fixture: three quads fanning around one shared edge.
    private func nonManifold() -> HalfEdgeMesh {
        var m = HalfEdgeMesh()
        let a = m.addVertex(SIMD3(0, 0, 0)), b = m.addVertex(SIMD3(1, 0, 0))
        let c = m.addVertex(SIMD3(1, 1, 0)), d = m.addVertex(SIMD3(0, 1, 0))
        let e = m.addVertex(SIMD3(1, 1, 1)), g = m.addVertex(SIMD3(0, 1, 1))
        let h = m.addVertex(SIMD3(1, 1, -1)), i = m.addVertex(SIMD3(0, 1, -1))
        m.addFace([a, b, c, d])   // edge (c,d) …
        m.addFace([d, c, e, g])   // … shared here …
        m.addFace([d, c, h, i])   // … and here → 3 faces on edge (c,d)
        return m
    }

    // MARK: Happy paths

    /// A flat grid shells into a closed box of the same footprint: V doubles, F
    /// grows by the inner copy plus one wall per boundary edge, χ jumps 1 → 2,
    /// and the enclosed volume equals footprint area × thickness.
    @Test func gridShellsIntoClosedBox() throws {
        let grid = Fixtures.grid(2) // 9 V, 12 E, 4 F, 8 boundary edges, χ = 1
        let r = try Solidify.apply(grid, selection: .faces(Set(grid.faceOrder)),
                                   params: .init(thickness: 0.25))
        #expect(r.delta == TopologyDelta(vertices: 9, edges: 20, faces: 12))
        #expect(r.mesh.boundaryEdges.isEmpty)          // closed
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        // Footprint 2×2 = 4, thickness 0.25 ⇒ volume 1.0.
        #expect(abs(abs(r.mesh.signedVolume) - 1.0) < 1e-9)
        guard case .faces(let faces) = r.resultSelection else { Issue.record("faces"); return }
        #expect(faces.count == 12)
        #expect(grid.faceCount == 4)                   // purity
    }

    /// A single quad shells into a closed six-face box (top, bottom, 4 walls).
    @Test func singleQuadCarriesSubsetsAndUVs() throws {
        let quad = uvQuad()
        let r = try Solidify.apply(quad, selection: .faces(Set(quad.faceOrder)),
                                   params: .init(thickness: 0.5))
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 8, faces: 5))
        #expect(r.mesh.faceCount == 6)
        #expect(r.mesh.boundaryEdges.isEmpty)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        // The inner face inherits the subset; UVs are carried (reversed).
        #expect(r.mesh.subsets["mat"]?.count == 2)
        let innerFace = r.mesh.faceOrder[quad.faceCount] // first added face
        #expect(r.mesh.faceCornerUVs[innerFace]?.count == 4)
        #expect(abs(abs(r.mesh.signedVolume) - 0.5) < 1e-9)
    }

    // MARK: Refusals

    @Test func refusesNonFaceSelection() {
        let grid = Fixtures.grid(1)
        #expect(throws: MeshOpError.emptySelection) {
            try Solidify.apply(grid, selection: .vertices([]), params: .init(thickness: 0.1))
        }
    }

    @Test func refusesEmptySelection() {
        let grid = Fixtures.grid(1)
        #expect(throws: MeshOpError.emptySelection) {
            try Solidify.apply(grid, selection: .faces([]), params: .init(thickness: 0.1))
        }
    }

    @Test func refusesPartialSelection() {
        let grid = Fixtures.grid(2)
        #expect(throws: (any Error).self) {
            try Solidify.apply(grid, selection: .faces([grid.faceOrder[0]]),
                               params: .init(thickness: 0.1))
        }
    }

    @Test func refusesNonPositiveThickness() {
        let grid = Fixtures.grid(1)
        #expect(throws: (any Error).self) {
            try Solidify.apply(grid, selection: .faces(Set(grid.faceOrder)),
                               params: .init(thickness: 0))
        }
    }

    @Test func refusesNonManifoldSurface() {
        let m = nonManifold()
        #expect(throws: (any Error).self) {
            try Solidify.apply(m, selection: .faces(Set(m.faceOrder)),
                               params: .init(thickness: 0.1))
        }
    }

    @Test func refusesClosedSurface() {
        let cube = Fixtures.cube() // no boundary edges
        #expect(throws: (any Error).self) {
            try Solidify.apply(cube, selection: .faces(Set(cube.faceOrder)),
                               params: .init(thickness: 0.1))
        }
    }
}
