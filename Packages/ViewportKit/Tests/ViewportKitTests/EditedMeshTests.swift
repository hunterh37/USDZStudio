import Testing
import Foundation
@testable import ViewportKit

private func unitQuad() -> EditedMeshData {
    EditedMeshData(
        primName: "Panel",
        positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
        faceLoops: [[0, 1, 2, 3]])
}

@Suite("MeshFlattener")
struct MeshFlattenerTests {

    @Test func quadFansToTwoTriangles() {
        let b = MeshFlattener.flatten(unitQuad())
        #expect(b.positions.count == 4)
        #expect(b.triangleIndices == [0, 1, 2, 0, 2, 3])
        // CCW quad in z=0 viewed from +z → normal +z, flat across the face.
        #expect(b.normals.allSatisfy { simd_distance($0, SIMD3(0, 0, 1)) < 1e-6 })
    }

    @Test func facesAreFlatShaded() {
        // Two quads sharing an edge but bent 90° — shared verts must be
        // duplicated so each face keeps its own normal.
        var data = unitQuad()
        data.positions += [SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
        data.faceLoops.append([3, 2, 4, 5])
        let b = MeshFlattener.flatten(data)
        #expect(b.positions.count == 8) // 4 + 4, shared verts duplicated
        #expect(simd_distance(b.normals[0], b.normals[4]) > 0.5)
    }

    @Test func subsetSelectionFlattensOnlyThoseFaces() {
        var data = unitQuad()
        data.positions += [SIMD3(2, 0, 0), SIMD3(2, 1, 0)]
        data.faceLoops.append([1, 4, 5, 2])
        let b = MeshFlattener.flatten(data, faces: [1])
        #expect(b.positions.count == 4)
        #expect(b.triangleIndices.count == 6)
    }

    @Test func skipsDegenerateOrOutOfRangeFaces() {
        var data = unitQuad()
        data.faceLoops.append([0, 1])      // too short
        data.faceLoops.append([0, 1, 99])  // out of range
        let b = MeshFlattener.flatten(data)
        #expect(b.triangleIndices.count == 6) // only the healthy quad
    }
}

@Suite("CameraRay + MeshPicker")
struct PickingTests {

    /// Camera on +z looking at the quad center: a center click must hit it.
    private func camera() -> OrbitCamera {
        var cam = OrbitCamera()
        cam.frame(center: SIMD3(0.5, 0.5, 0), radius: 1)
        return cam
    }

    @Test func centerClickHitsTheQuad() {
        let cam = camera()
        let ray = CameraRay.make(camera: cam, viewSize: CGSize(width: 800, height: 600),
                                 point: CGPoint(x: 400, y: 300))!
        let hit = MeshPicker.pickFace(ray: ray, in: unitQuad())
        #expect(hit?.faceIndex == 0)
    }

    @Test func offModelClickMisses() {
        let cam = camera()
        let ray = CameraRay.make(camera: cam, viewSize: CGSize(width: 800, height: 600),
                                 point: CGPoint(x: 10, y: 10))!
        #expect(MeshPicker.pickFace(ray: ray, in: unitQuad()) == nil)
    }

    @Test func nearestFaceWinsWhenStacked() {
        var data = unitQuad()
        // Second quad directly behind the first (z = −1).
        data.positions += [SIMD3(0, 0, -1), SIMD3(1, 0, -1), SIMD3(1, 1, -1), SIMD3(0, 1, -1)]
        data.faceLoops.append([4, 5, 6, 7])
        let ray = CameraRay.Ray(origin: SIMD3(0.5, 0.5, 5), direction: SIMD3(0, 0, -1))
        let hit = MeshPicker.pickFace(ray: ray, in: data)
        #expect(hit?.faceIndex == 0) // front quad, not the one behind
    }

    @Test func degenerateRayInputsReturnNil() {
        #expect(CameraRay.make(camera: camera(), viewSize: .zero, point: .zero) == nil)
    }

    @Test func rayDirectionIsUnitLength() {
        let ray = CameraRay.make(camera: camera(), viewSize: CGSize(width: 800, height: 600),
                                 point: CGPoint(x: 123, y: 456))!
        #expect(abs((ray.direction * ray.direction).sum() - 1) < 1e-9)
    }
}

private func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    ((a - b) * (a - b)).sum().squareRoot()
}

/// `EditedMeshData.update(from:)` classifies each drag frame so the viewport can
/// take the cheap in-place path for a position-only move and only pay for a full
/// rebuild (mesh regen + BVH) when topology actually changes — the core of
/// issue #1's extrude-drag fix.
@Suite("EditedMeshData.update(from:) classification")
struct EditedMeshUpdateTests {

    @Test("No previous data always requires a full rebuild")
    func noPreviousIsRebuild() {
        #expect(unitQuad().update(from: nil) == .rebuild)
    }

    @Test("Identical data (only the revision bumped) needs no redraw")
    func revisionOnlyIsNone() {
        let a = unitQuad()
        var b = unitQuad()
        b.revision = a.revision + 1
        #expect(b.update(from: a) == .none)
    }

    @Test("Moving a vertex, same topology, is a position-only update")
    func movedVertexIsPositions() {
        let a = unitQuad()
        var b = unitQuad()
        b.positions[2] = SIMD3(1, 1, 0.5) // extrude one corner in Z
        b.revision = a.revision + 1
        #expect(b.update(from: a) == .positions)
    }

    @Test("A changed selection forces a full rebuild")
    func changedSelectionIsRebuild() {
        let a = unitQuad()
        var b = unitQuad()
        b.selectedFaces = [0]
        #expect(b.update(from: a) == .rebuild)
    }

    @Test("A changed face topology forces a full rebuild")
    func changedTopologyIsRebuild() {
        let a = unitQuad()
        var b = unitQuad()
        b.faceLoops = [[0, 1, 2], [0, 2, 3]] // same verts, different faces
        #expect(b.update(from: a) == .rebuild)
    }

    @Test("A changed vertex count forces a full rebuild")
    func changedVertexCountIsRebuild() {
        let a = unitQuad()
        var b = unitQuad()
        b.positions.append(SIMD3(2, 2, 2)) // extrude added geometry
        #expect(b.update(from: a) == .rebuild)
    }

    @Test("A different prim forces a full rebuild")
    func differentPrimIsRebuild() {
        let a = unitQuad()
        var b = unitQuad()
        b.primName = "OtherPanel"
        #expect(b.update(from: a) == .rebuild)
    }

    @Test("Position-only classification holds with a stable non-empty selection")
    func positionsWithStableSelection() {
        var a = unitQuad(); a.selectedFaces = [0]
        var b = unitQuad(); b.selectedFaces = [0]
        b.positions[0] = SIMD3(0, 0, 0.25)
        #expect(b.update(from: a) == .positions)
    }
}
