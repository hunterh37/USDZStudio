import Testing
import Foundation
import simd
@testable import ViewportKit

@Suite("LiveMeshBuffers")
struct LiveMeshBuffersTests {

    /// Two triangles forming a quad in z=0, sharing the 0–2 diagonal.
    private func quad() -> ([SIMD3<Float>], [[Int]]) {
        ([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
         [[0, 1, 2], [0, 2, 3]])
    }

    @Test("Shared-vertex layout keeps one slot per prim vertex")
    func sharedVertexLayout() {
        let (pos, loops) = quad()
        let b = LiveMeshBuffers(positions: pos, faceLoops: loops)
        #expect(b.positions.count == 4)               // shared, not per-face duplicated
        #expect(b.normals.count == 4)
        #expect(b.triangleIndices.count == 6)          // 2 triangles
    }

    @Test("A flat quad has +Z normals everywhere")
    func flatNormals() {
        let (pos, loops) = quad()
        let b = LiveMeshBuffers(positions: pos, faceLoops: loops)
        for n in b.normals {
            #expect(simd_length(n - SIMD3(0, 0, 1)) < 1e-6)
        }
    }

    @Test("Degenerate/short loops are skipped and unreferenced vertices get a fallback normal")
    func degenerateHandling() {
        let pos: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]
        let b = LiveMeshBuffers(positions: pos, faceLoops: [[0, 1]]) // < 3 verts
        #expect(b.triangleIndices.isEmpty)
        #expect(b.normals.count == 3)
        #expect(simd_length(b.normals[0] - SIMD3(0, 1, 0)) < 1e-6) // fallback
    }

    @Test("A partial position change moves only the listed slot")
    func partialPositionWrite() {
        let (pos, loops) = quad()
        var b = LiveMeshBuffers(positions: pos, faceLoops: loops)
        b.applyPositionChanges([1: SIMD3(1, 0, 3)])
        #expect(b.positions[1] == SIMD3(1, 0, 3))
        #expect(b.positions[0] == SIMD3(0, 0, 0)) // untouched
        #expect(b.positions[3] == SIMD3(0, 1, 0)) // untouched
    }

    @Test("Moving a vertex out of plane tilts the normals of its incident faces' corners")
    func normalsRecomputeOnAffectedRing() {
        let (pos, loops) = quad()
        var b = LiveMeshBuffers(positions: pos, faceLoops: loops)
        b.applyPositionChanges([2: SIMD3(1, 1, 1)]) // lift the shared corner
        // Vertex 2 is in both faces → its normal must no longer be pure +Z.
        #expect(simd_length(b.normals[2] - SIMD3(0, 0, 1)) > 1e-3)
        // A corner of an incident face (vertex 0, shared diagonal) also shifts.
        #expect(simd_length(b.normals[0] - SIMD3(0, 0, 1)) > 1e-3)
    }

    @Test("An empty change set is a no-op")
    func emptyChangeNoOp() {
        let (pos, loops) = quad()
        let b = LiveMeshBuffers(positions: pos, faceLoops: loops)
        var b2 = b
        b2.applyPositionChanges([:])
        #expect(b2 == b)
    }

    @Test("Out-of-range change indices are ignored safely")
    func outOfRangeIgnored() {
        let (pos, loops) = quad()
        var b = LiveMeshBuffers(positions: pos, faceLoops: loops)
        b.applyPositionChanges([99: SIMD3(9, 9, 9)])
        #expect(b.positions.count == 4)
    }
}

@Suite("OverlayLOD")
struct OverlayLODTests {

    @Test("Below the cap, everything visible is drawn")
    func underCapDrawsAll() {
        let chosen = OverlayLOD.sample(visible: [1, 2, 3], pinned: [], cap: 10)
        #expect(chosen == [1, 2, 3])
    }

    @Test("Pinned vertices are always drawn even when they'd exceed the cap")
    func pinnedAlwaysDrawn() {
        let chosen = OverlayLOD.sample(visible: Array(0..<100), pinned: [7, 42], cap: 3)
        #expect(chosen.contains(7))
        #expect(chosen.contains(42))
    }

    @Test("The drawn set never exceeds the cap")
    func respectsCap() {
        let chosen = OverlayLOD.sample(visible: Array(0..<1000), pinned: [], cap: 50)
        #expect(chosen.count <= 50)
    }

    @Test("Sampling is deterministic (stable frame to frame)")
    func deterministic() {
        let a = OverlayLOD.sample(visible: Array(0..<1000), pinned: [1], cap: 50)
        let b = OverlayLOD.sample(visible: Array(0..<1000), pinned: [1], cap: 50)
        #expect(a == b)
    }

    @Test("A zero cap draws only the pinned set")
    func zeroCap() {
        #expect(OverlayLOD.sample(visible: [1, 2, 3], pinned: [9], cap: 0) == [9])
    }

    @Test("When pinned already fills the cap, no extras are added")
    func pinnedFillsCap() {
        let chosen = OverlayLOD.sample(visible: [1, 2, 3, 4, 5], pinned: [8, 9], cap: 2)
        #expect(chosen == [8, 9])
    }
}
