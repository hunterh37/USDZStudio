import Testing
import Foundation
import CoreGraphics
import simd
@testable import ViewportKit

@Suite("VertexAccelerator")
struct VertexAcceleratorTests {

    /// Orthographic projection: drop Z, treat X/Y as screen coords. Points with
    /// z < 0 are "behind the camera" → nil (exercises the conservative descend).
    private func ortho(_ p: SIMD3<Float>) -> CGPoint? {
        p.z < 0 ? nil : CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    /// A jittered grid of `n × n` points in the z=0 plane for scale/parity tests.
    private func gridPositions(_ n: Int) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        for y in 0..<n { for x in 0..<n { pts.append(SIMD3(Float(x), Float(y), 0)) } }
        return pts
    }

    @Test("An empty accelerator answers nothing")
    func empty() {
        let acc = VertexAccelerator(positions: [])
        #expect(acc.isEmpty)
        #expect(acc.vertices(inScreenRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                             project: ortho).isEmpty)
        #expect(acc.nearestVertex(toScreenPoint: .zero, tolerance: 5, project: ortho) == nil)
    }

    @Test("Region select returns exactly the vertices inside the rect (BVH == brute force)")
    func regionSelectParity() {
        let pts = gridPositions(20) // 400 points, forces a deep tree
        let acc = VertexAccelerator(positions: pts)
        let rect = CGRect(x: 2, y: 2, width: 5.5, height: 5.5)
        let got = acc.vertices(inScreenRect: rect, project: ortho)
        let brute = Set(pts.indices.filter { i in
            guard let sp = ortho(pts[i]) else { return false }
            return rect.contains(sp)
        })
        #expect(got == brute)
    }

    @Test("Nearest pick returns the closest vertex within tolerance")
    func nearestWithinTolerance() {
        let pts = gridPositions(10)
        let acc = VertexAccelerator(positions: pts)
        // Cursor near (3,4) → grid index 4*10 + 3 = 43.
        let hit = acc.nearestVertex(toScreenPoint: CGPoint(x: 3.1, y: 3.9),
                                    tolerance: 0.5, project: ortho)
        #expect(hit == 43)
    }

    @Test("Nearest pick misses when nothing is within tolerance")
    func nearestOutOfTolerance() {
        let acc = VertexAccelerator(positions: gridPositions(5))
        let hit = acc.nearestVertex(toScreenPoint: CGPoint(x: 100, y: 100),
                                    tolerance: 0.4, project: ortho)
        #expect(hit == nil)
    }

    @Test("Exact ties break to the lowest vertex index")
    func tieBreakLowestIndex() {
        // Two coincident-in-screen points; the lower index must win.
        let pts = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 5)] // both project to (0,0)
        let acc = VertexAccelerator(positions: pts)
        let hit = acc.nearestVertex(toScreenPoint: .zero, tolerance: 1, project: ortho)
        #expect(hit == 0)
    }

    @Test("Vertices behind the camera are never selected")
    func behindCameraExcluded() {
        let pts = [SIMD3<Float>(1, 1, 0), SIMD3<Float>(1, 1, -1)] // second is behind
        let acc = VertexAccelerator(positions: pts)
        let got = acc.vertices(inScreenRect: CGRect(x: 0, y: 0, width: 5, height: 5),
                               project: ortho)
        #expect(got == [0])
    }

    @Test("A node with a corner behind the camera is descended, not culled")
    func straddlingNodeIsDescended() {
        // Points spanning the near plane so node AABBs straddle z=0; every
        // in-front point in the rect must still be found (no false cull).
        var pts: [SIMD3<Float>] = []
        for i in 0..<64 { pts.append(SIMD3(Float(i % 8), Float(i / 8), i % 2 == 0 ? 1 : -1)) }
        let acc = VertexAccelerator(positions: pts)
        let rect = CGRect(x: -1, y: -1, width: 10, height: 10)
        let got = acc.vertices(inScreenRect: rect, project: ortho)
        let brute = Set(pts.indices.filter { ortho(pts[$0]).map(rect.contains) ?? false })
        #expect(got == brute)
    }
}
