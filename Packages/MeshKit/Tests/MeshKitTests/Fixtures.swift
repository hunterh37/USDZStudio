import Foundation
@testable import MeshKit

enum Fixtures {

    /// Unit cube, 6 quads, outward winding. V8 E12 F6, χ = 2, volume = 1.
    static func cubeFlat() -> FlatMesh {
        FlatMesh(
            points: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), // z=0
                SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1), // z=1
            ],
            faceVertexCounts: [4, 4, 4, 4, 4, 4],
            faceVertexIndices: [
                0, 3, 2, 1, // bottom (z=0, normal −z)
                4, 5, 6, 7, // top (z=1, normal +z)
                0, 1, 5, 4, // front (y=0, normal −y)
                2, 3, 7, 6, // back (y=1, normal +y)
                1, 2, 6, 5, // right (x=1, normal +x)
                3, 0, 4, 7, // left (x=0, normal −x)
            ])
    }

    static func cube() -> HalfEdgeMesh { try! MeshIO.mesh(from: cubeFlat()) }

    /// Cube with the top quad removed → open box with a 4-vertex boundary loop.
    static func openBox() -> HalfEdgeMesh {
        var flat = cubeFlat()
        flat.faceVertexCounts.remove(at: 1)
        flat.faceVertexIndices.removeSubrange(4..<8)
        return try! MeshIO.mesh(from: flat)
    }

    /// n×n quad grid in the z=0 plane (open surface, +z normals).
    static func grid(_ n: Int) -> HalfEdgeMesh {
        var points: [SIMD3<Double>] = []
        for y in 0...n { for x in 0...n { points.append(SIMD3(Double(x), Double(y), 0)) } }
        var counts: [Int] = [], indices: [Int] = []
        let w = n + 1
        for y in 0..<n {
            for x in 0..<n {
                counts.append(4)
                indices += [y * w + x, y * w + x + 1, (y + 1) * w + x + 1, (y + 1) * w + x]
            }
        }
        return try! MeshIO.mesh(from: FlatMesh(points: points, faceVertexCounts: counts,
                                               faceVertexIndices: indices))
    }

    /// Face ID of the cube's top face in `cube()` (import order → FaceID(1)).
    static let cubeTop = FaceID(1)
}
