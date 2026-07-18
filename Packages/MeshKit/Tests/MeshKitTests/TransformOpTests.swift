import Testing
import Foundation
@testable import MeshKit

@Suite("TransformComponents")
struct TransformOpTests {

    private let tolerance = 1e-12

    @Test func translateWholeMeshShiftsEveryVertex() throws {
        let cube = Fixtures.cube()
        let all = Set(cube.vertexOrder)
        let r = try TransformComponents.apply(
            cube, selection: .vertices(all),
            params: .init(translation: SIMD3(1, 2, 3)))
        #expect(r.delta == TopologyDelta(vertices: 0, edges: 0, faces: 0))
        for v in all {
            #expect(simd_length(r.mesh.positions[v]! - cube.positions[v]! - SIMD3(1, 2, 3)) < tolerance)
        }
        #expect(abs(r.mesh.signedVolume - cube.signedVolume) < tolerance) // rigid
    }

    @Test func faceSelectionMovesOnlyItsVertices() throws {
        let cube = Fixtures.cube()
        let r = try TransformComponents.apply(
            cube, selection: .faces([Fixtures.cubeTop]),
            params: .init(translation: SIMD3(0, 1, 0)))
        let topVerts = Set(cube.faceLoops[Fixtures.cubeTop]!)
        for v in cube.vertexOrder {
            let moved = topVerts.contains(v)
            let expected = cube.positions[v]! + (moved ? SIMD3(0, 1, 0) : .zero)
            #expect(simd_length(r.mesh.positions[v]! - expected) < tolerance)
        }
        #expect(MeshInvariants.violations(in: r.mesh).isEmpty)
    }

    @Test func scaleAboutCentroidScalesVolumeCubically() throws {
        let cube = Fixtures.cube()
        let r = try TransformComponents.apply(
            cube, selection: .vertices(Set(cube.vertexOrder)),
            params: .init(scale: SIMD3(2, 2, 2)))
        #expect(abs(r.mesh.signedVolume - 8) < 1e-9)
        // Centroid pivot: the center must not move.
        var center = SIMD3<Double>()
        for v in r.mesh.vertexOrder { center += r.mesh.positions[v]! }
        center /= Double(r.mesh.vertexCount)
        #expect(simd_length(center - SIMD3(0.5, 0.5, 0.5)) < tolerance)
    }

    @Test func rotate90AboutYIsExact() throws {
        let cube = Fixtures.cube()
        let r = try TransformComponents.apply(
            cube, selection: .vertices(Set(cube.vertexOrder)),
            params: .init(rotationDegrees: SIMD3(0, 90, 0), pivot: .origin))
        // (x, y, z) → (z, y, −x) for a +90° Y rotation.
        for v in cube.vertexOrder {
            let p = cube.positions[v]!
            #expect(simd_length(r.mesh.positions[v]! - SIMD3(p.z, p.y, -p.x)) < 1e-12)
        }
        #expect(abs(r.mesh.signedVolume - 1) < 1e-9) // rigid, orientation preserved
    }

    @Test func explicitPointPivotIsRespected() throws {
        let cube = Fixtures.cube()
        let pivot = SIMD3<Double>(1, 1, 1)
        let r = try TransformComponents.apply(
            cube, selection: .vertices(Set(cube.vertexOrder)),
            params: .init(scale: SIMD3(0.5, 0.5, 0.5), pivot: .point(pivot)))
        // The pivot corner (vertex at (1,1,1)) must be a fixed point.
        let corner = cube.vertexOrder.first { cube.positions[$0]! == pivot }!
        #expect(r.mesh.positions[corner]! == pivot)
    }

    @Test func edgeSelectionMovesExactlyTwoVertices() throws {
        let cube = Fixtures.cube()
        let edge = EdgeKey(VertexID(4), VertexID(5))
        let r = try TransformComponents.apply(
            cube, selection: .edges([edge]),
            params: .init(translation: SIMD3(0, 0, 0.25)))
        let moved = cube.vertexOrder.filter { r.mesh.positions[$0]! != cube.positions[$0]! }
        #expect(Set(moved) == [VertexID(4), VertexID(5)])
    }

    // MARK: - Preconditions and failure modes

    @Test func rejectsEmptySelectionIdentityAndZeroScale() throws {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.emptySelection) {
            try TransformComponents.apply(cube, selection: .vertices([]),
                                          params: .init(translation: SIMD3(1, 0, 0)))
        }
        #expect(throws: MeshOpError.self) { // identity
            try TransformComponents.apply(cube, selection: .vertices(Set(cube.vertexOrder)),
                                          params: .init())
        }
        #expect(throws: MeshOpError.self) { // zero scale
            try TransformComponents.apply(cube, selection: .vertices(Set(cube.vertexOrder)),
                                          params: .init(scale: SIMD3(1, 0, 1)))
        }
    }

    @Test func rejectsUnknownComponents() throws {
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.unknownComponent("vertex 99")) {
            try TransformComponents.apply(cube, selection: .vertices([VertexID(99)]),
                                          params: .init(translation: SIMD3(1, 0, 0)))
        }
        #expect(throws: MeshOpError.self) {
            try TransformComponents.apply(cube, selection: .faces([FaceID(99)]),
                                          params: .init(translation: SIMD3(1, 0, 0)))
        }
        #expect(throws: MeshOpError.self) {
            try TransformComponents.apply(
                cube, selection: .edges([EdgeKey(VertexID(0), VertexID(6))]), // diagonal, no edge
                params: .init(translation: SIMD3(1, 0, 0)))
        }
    }

    @Test func degenerateResultIsRejectedByInvariants() throws {
        // Collapsing one face's vertices onto a line zeroes its area → the
        // shared post-op invariant check must throw, not return garbage.
        let cube = Fixtures.cube()
        #expect(throws: MeshOpError.self) {
            try TransformComponents.apply(
                cube, selection: .faces([Fixtures.cubeTop]),
                params: .init(scale: SIMD3(1e-15, 1, 1e-15)))
        }
    }

    @Test func rotationMatrixIsOrthonormal() {
        let m = TransformComponents.rotationMatrixXYZ(degrees: SIMD3(31, -47, 112))
        let cols = [SIMD3(m.rows.0.x, m.rows.1.x, m.rows.2.x),
                    SIMD3(m.rows.0.y, m.rows.1.y, m.rows.2.y),
                    SIMD3(m.rows.0.z, m.rows.1.z, m.rows.2.z)]
        for i in 0..<3 {
            for j in 0..<3 {
                let expected: Double = i == j ? 1 : 0
                #expect(abs(simd_dot(cols[i], cols[j]) - expected) < 1e-12)
            }
        }
    }
}
