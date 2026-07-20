import Foundation
import MeshKit
import ViewportKit

/// Bridges a `MeshKit` shape into the viewport's own geometry representation for
/// the library preview. Pure and RealityKit-free so the projection stays
/// unit-testable; the actual GPU rendering lives in `ViewportKit.ShapePreviewView`.
enum LibraryPreviewGeometry {

    /// Converts a flattened mesh into `ViewportMeshData` (float positions +
    /// per-face index loops). Returns `nil` when there is no drawable geometry
    /// (no points or no faces), so callers can fall back to an empty preview.
    static func viewportMesh(from flat: FlatMesh) -> ViewportMeshData? {
        guard !flat.points.isEmpty, !flat.faceVertexCounts.isEmpty else { return nil }
        let positions = flat.points.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }

        var loops: [[Int]] = []
        loops.reserveCapacity(flat.faceVertexCounts.count)
        var cursor = 0
        let indexCount = flat.faceVertexIndices.count
        for count in flat.faceVertexCounts {
            guard count > 0, cursor + count <= indexCount else { return nil }
            let loop = Array(flat.faceVertexIndices[cursor..<cursor + count])
            // A loop that points outside the vertex buffer would crash the GPU
            // flattener; reject the whole mesh rather than emit corrupt geometry.
            guard loop.allSatisfy({ $0 >= 0 && $0 < positions.count }) else { return nil }
            loops.append(loop)
            cursor += count
        }
        return ViewportMeshData(positions: positions, faceLoops: loops)
    }

    /// Builds the preview geometry for a library entry, or `nil` if the mesh
    /// fails to build or carries no drawable faces.
    static func viewportMesh(for entry: ShapeEntry) -> ViewportMeshData? {
        guard let mesh = try? entry.build() else { return nil }
        return viewportMesh(from: MeshIO.flat(from: mesh))
    }
}
