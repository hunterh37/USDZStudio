import Testing
import Foundation
@testable import MeshKit

@Suite("Area-weighted vertex normals")
struct VertexNormalsTests {

    /// A single CCW triangle in the z=0 plane must yield a unit +Z normal at
    /// every vertex.
    @Test func planarTriangleFacesUp() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 2])
        let normals = VertexNormals.smooth(for: flat)
        #expect(normals.count == 3)
        for n in normals {
            #expect(abs(n.x) < 1e-12)
            #expect(abs(n.y) < 1e-12)
            #expect(abs(n.z - 1.0) < 1e-12)
        }
    }

    /// A closed cube's corner normals point diagonally outward (each corner is
    /// shared by three axis-aligned faces of equal area).
    @Test func cubeCornersPointOutward() {
        let mesh = Fixtures.cube()
        let flat = MeshIO.flat(from: mesh)
        let normals = VertexNormals.smooth(for: flat)
        #expect(normals.count == flat.points.count)
        for (i, n) in normals.enumerated() {
            let p = flat.points[i]
            // Corner normal should share the sign of the (centered) position on
            // every axis — i.e. it genuinely points away from the interior.
            #expect(n.x * p.x >= 0)
            #expect(n.y * p.y >= 0)
            #expect(n.z * p.z >= 0)
            let length = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
            #expect(abs(length - 1.0) < 1e-9)
        }
    }

    @Test func flattenedLayoutParallelsPoints() {
        let mesh = Fixtures.cube()
        let flat = MeshIO.flat(from: mesh)
        let vecs = VertexNormals.smooth(for: flat)
        let arr = VertexNormals.smoothFlat(for: flat)
        #expect(arr.count == vecs.count * 3)
        for (i, n) in vecs.enumerated() {
            #expect(arr[i * 3] == n.x)
            #expect(arr[i * 3 + 1] == n.y)
            #expect(arr[i * 3 + 2] == n.z)
        }
    }

    // MARK: - Honest declines

    @Test func emptyMeshYieldsNoNormals() {
        let flat = FlatMesh(points: [], faceVertexCounts: [], faceVertexIndices: [])
        #expect(VertexNormals.smooth(for: flat).isEmpty)
        #expect(VertexNormals.smoothFlat(for: flat).isEmpty)
    }

    @Test func countIndexMismatchDeclines() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            faceVertexCounts: [4], // claims 4 corners but only 3 indices
            faceVertexIndices: [0, 1, 2])
        #expect(VertexNormals.smooth(for: flat).isEmpty)
    }

    @Test func degenerateFaceDeclines() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)],
            faceVertexCounts: [2], // a face needs at least 3 corners
            faceVertexIndices: [0, 1])
        #expect(VertexNormals.smooth(for: flat).isEmpty)
    }

    @Test func outOfRangeIndexDeclines() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 9])
        #expect(VertexNormals.smooth(for: flat).isEmpty)
    }

    /// Two coincident triangles wound in opposite directions cancel exactly, so
    /// the shared vertices get an honest zero normal rather than a fabricated
    /// direction.
    @Test func cancellingFacesYieldZeroNormal() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            faceVertexCounts: [3, 3],
            faceVertexIndices: [0, 1, 2, 0, 2, 1])
        let normals = VertexNormals.smooth(for: flat)
        #expect(normals.count == 3)
        for n in normals {
            #expect(n == SIMD3<Double>.zero)
        }
    }
}
