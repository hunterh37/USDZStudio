import Testing
import Foundation
import MeshKit
import ViewportKit
@testable import EditorUI

struct LibraryPreviewGeometryTests {

    // MARK: viewportMesh(from flat:)

    @Test func rejectsEmptyPoints() {
        let flat = FlatMesh(points: [], faceVertexCounts: [], faceVertexIndices: [])
        #expect(LibraryPreviewGeometry.viewportMesh(from: flat) == nil)
    }

    @Test func rejectsPointsWithoutFaces() {
        let flat = FlatMesh(points: [SIMD3(0, 0, 0)], faceVertexCounts: [], faceVertexIndices: [])
        #expect(LibraryPreviewGeometry.viewportMesh(from: flat) == nil)
    }

    @Test func buildsLoopsFromCountsAndIndices() throws {
        // Two triangles sharing the four corners of a quad.
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
            faceVertexCounts: [3, 3],
            faceVertexIndices: [0, 1, 2, 0, 2, 3])
        let mesh = try #require(LibraryPreviewGeometry.viewportMesh(from: flat))
        #expect(mesh.positions.count == 4)
        #expect(mesh.faceLoops == [[0, 1, 2], [0, 2, 3]])
        #expect(mesh.positions[1] == SIMD3<Float>(1, 0, 0))
    }

    @Test func rejectsIndexOutOfRange() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)],
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 9]) // 9 is out of bounds
        #expect(LibraryPreviewGeometry.viewportMesh(from: flat) == nil)
    }

    @Test func rejectsTruncatedIndexBuffer() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)],
            faceVertexCounts: [3, 3], // claims two triangles…
            faceVertexIndices: [0, 1, 2]) // …but only supplies one
        #expect(LibraryPreviewGeometry.viewportMesh(from: flat) == nil)
    }

    @Test func rejectsZeroVertexFace() {
        let flat = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)],
            faceVertexCounts: [0, 3],
            faceVertexIndices: [0, 1, 2])
        #expect(LibraryPreviewGeometry.viewportMesh(from: flat) == nil)
    }

    // MARK: viewportMesh(for entry:)

    @Test func everyLibraryEntryProducesDrawableGeometry() throws {
        for entry in ShapeLibrary.all {
            let mesh = try #require(LibraryPreviewGeometry.viewportMesh(for: entry),
                                    "\(entry.id) produced no preview geometry")
            #expect(!mesh.positions.isEmpty)
            #expect(!mesh.faceLoops.isEmpty)
        }
    }
}
