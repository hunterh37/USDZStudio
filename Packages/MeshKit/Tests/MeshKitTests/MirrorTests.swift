import Testing
import Foundation
@testable import MeshKit

@Suite("Mirror")
struct MirrorTests {

    /// Single UV-tagged quad in the z = 0 plane (open surface, +z normal), used
    /// to exercise the subset/UV-carrying paths.
    private func uvQuad() -> HalfEdgeMesh {
        var m = HalfEdgeMesh()
        let a = m.addVertex(SIMD3(0, 0, 0)), b = m.addVertex(SIMD3(1, 0, 0))
        let c = m.addVertex(SIMD3(1, 1, 0)), d = m.addVertex(SIMD3(0, 1, 0))
        let f = m.addFace([a, b, c, d],
                          uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        m.addFaceToSubset(f, subset: "mat")
        return m
    }

    // MARK: Happy paths

    /// A plane that misses the mesh duplicates it into a second, disjoint shell:
    /// no vertices are welded, V/E/F all double, χ doubles (2 → 4) and the
    /// analytic volume doubles (two unit cubes).
    @Test func planeMissingMeshDoublesIt() throws {
        let cube = Fixtures.cube() // z ∈ [0, 1]
        let r = try Mirror.apply(cube, selection: .faces(Set(cube.faceOrder)),
                                 params: .init(axis: .z, coordinate: -1))
        #expect(r.delta == TopologyDelta(vertices: 8, edges: 12, faces: 6))
        #expect(r.mesh.vertexCount == 16)
        #expect(r.mesh.faceCount == 12)
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 4)
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
        #expect(abs(r.mesh.signedVolume - 2.0) < 1e-9)
        guard case .faces(let faces) = r.resultSelection else { Issue.record("faces"); return }
        #expect(faces.count == 6)
        // Purity: the input is untouched.
        #expect(cube.faceCount == 6)
    }

    /// A plane on the open boundary welds the reflection shut: on-plane rim
    /// vertices are shared, so an open box mirrors into a closed manifold with
    /// no boundary edges and Euler characteristic 2.
    @Test func planeOnBoundaryWeldsClosed() throws {
        let box = Fixtures.openBox() // cube missing top; rim at z = 1
        let r = try Mirror.apply(box, selection: .faces(Set(box.faceOrder)),
                                 params: .init(axis: .z, coordinate: 1))
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 8, faces: 5))
        #expect(r.mesh.boundaryEdges.isEmpty)          // closed
        #expect(MeshInvariants.eulerCharacteristic(of: r.mesh) == 2)
        #expect(MeshInvariants.violations(in: r.mesh, allowBoundaries: false).isEmpty)
        #expect(abs(r.mesh.signedVolume - 2.0) < 1e-9) // 1×1×2 box
    }

    /// Mirrored faces inherit the source face's subset membership, and per-corner
    /// UVs are carried across (reversed to match the flipped winding).
    @Test func carriesSubsetsAndUVs() throws {
        let quad = uvQuad()
        let r = try Mirror.apply(quad, selection: .faces(Set(quad.faceOrder)),
                                 params: .init(axis: .z, coordinate: -1))
        #expect(r.delta == TopologyDelta(vertices: 4, edges: 4, faces: 1))
        #expect(r.mesh.subsets["mat"]?.count == 2)     // original + mirror
        let mirroredFace = r.mesh.faceOrder.last!
        let uvs = r.mesh.faceCornerUVs[mirroredFace]
        #expect(uvs?.count == 4)
        // Reversed winding ⇒ reversed corner-UV order.
        #expect(uvs?.first == SIMD2(0, 1))
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    /// Each axis reflects along the correct coordinate (drives `axisIndex`).
    @Test(arguments: [Mirror.Axis.x, .y, .z])
    func mirrorsAlongEachAxis(axis: Mirror.Axis) throws {
        let cube = Fixtures.cube() // spans [0,1] on every axis
        let r = try Mirror.apply(cube, selection: .faces(Set(cube.faceOrder)),
                                 params: .init(axis: axis, coordinate: -1))
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
        let k = Mirror.axisIndex(axis)
        // The reflected shell lives entirely below the plane on that axis.
        #expect(r.mesh.positions.values.map { $0[k] }.min()! < -1)
    }

    // MARK: Refusals (loud, never silent)

    @Test func refusesNonFaceSelection() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try Mirror.apply(cube, selection: .edges([EdgeKey(VertexID(0), VertexID(1))]),
                             params: .init(axis: .x))
        }
    }

    @Test func refusesEmptySelection() {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try Mirror.apply(cube, selection: .faces([]), params: .init(axis: .x))
        }
    }

    @Test func refusesPartialSelection() {
        let cube = Fixtures.cube()
        #expect(throws: (any Error).self) {
            try Mirror.apply(cube, selection: .faces([FaceID(0)]), params: .init(axis: .x))
        }
    }

    @Test func refusesPlaneThroughMesh() {
        let cube = Fixtures.cube() // z ∈ [0,1]
        // Plane at z = 0.5 cuts the cube: vertices on both sides.
        #expect(throws: (any Error).self) {
            try Mirror.apply(cube, selection: .faces(Set(cube.faceOrder)),
                             params: .init(axis: .z, coordinate: 0.5))
        }
    }

    @Test func refusesFaceLyingOnPlane() {
        let cube = Fixtures.cube()
        // Plane at z = 0 contains the whole bottom face.
        #expect(throws: (any Error).self) {
            try Mirror.apply(cube, selection: .faces(Set(cube.faceOrder)),
                             params: .init(axis: .z, coordinate: 0))
        }
    }
}
