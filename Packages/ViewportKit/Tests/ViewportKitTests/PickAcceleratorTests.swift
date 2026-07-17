import Testing
import Foundation
@testable import ViewportKit

@Suite("PickAccelerator (BVH)")
struct PickAcceleratorTests {

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Random quad grid with jittered heights — many triangles, varied layout.
    private func randomMesh(_ rng: inout SplitMix64, size: Int) -> EditedMeshData {
        var positions: [SIMD3<Float>] = []
        let w = size + 1
        for y in 0...size {
            for x in 0...size {
                positions.append(SIMD3(Float(x), Float(y),
                                       Float.random(in: -0.4...0.4, using: &rng)))
            }
        }
        var loops: [[Int]] = []
        for y in 0..<size {
            for x in 0..<size {
                loops.append([y * w + x, y * w + x + 1, (y + 1) * w + x + 1, (y + 1) * w + x])
            }
        }
        return EditedMeshData(primName: "Grid", positions: positions, faceLoops: loops)
    }

    /// The contract: BVH answers == brute-force answers, for every ray.
    @Test(arguments: 0..<20)
    func matchesBruteForceOnRandomRays(iteration: UInt64) {
        var rng = SplitMix64(seed: 0xBEEF &+ iteration)
        let mesh = randomMesh(&rng, size: Int.random(in: 1...8, using: &rng))
        let bvh = PickAccelerator(mesh)
        for _ in 0..<50 {
            let origin = SIMD3<Double>(Double.random(in: -2...10, using: &rng),
                                       Double.random(in: -2...10, using: &rng),
                                       Double.random(in: 2...6, using: &rng))
            var direction = SIMD3<Double>(Double.random(in: -1...1, using: &rng),
                                          Double.random(in: -1...1, using: &rng),
                                          Double.random(in: -1 ... -0.1, using: &rng))
            let len = (direction * direction).sum().squareRoot()
            direction /= len
            let ray = CameraRay.Ray(origin: origin, direction: direction)
            let expected = MeshPicker.pickFace(ray: ray, in: mesh)
            let actual = bvh.pickFace(ray: ray)
            #expect(actual?.faceIndex == expected?.faceIndex,
                    "BVH disagreed with brute force on iteration \(iteration)")
            if let a = actual, let e = expected {
                #expect(abs(a.distance - e.distance) < 1e-9)
            }
        }
    }

    @Test func emptyMeshReturnsNil() {
        let bvh = PickAccelerator(EditedMeshData(primName: "x", positions: [], faceLoops: []))
        let ray = CameraRay.Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(bvh.pickFace(ray: ray) == nil)
    }

    @Test func axisAlignedRayOnBoxBoundary() {
        // Degenerate-adjacent: direction has zero components (infinite slab
        // inverses); must not crash or misreport.
        var rng = SplitMix64(seed: 7)
        let mesh = randomMesh(&rng, size: 4)
        let bvh = PickAccelerator(mesh)
        let ray = CameraRay.Ray(origin: SIMD3(2.0, 2.0, 5), direction: SIMD3(0, 0, -1))
        #expect(bvh.pickFace(ray: ray)?.faceIndex == MeshPicker.pickFace(ray: ray, in: mesh)?.faceIndex)
    }

    @Test func scalesToLargeMeshes() {
        var rng = SplitMix64(seed: 42)
        let mesh = randomMesh(&rng, size: 100) // 10k quads = 20k triangles
        let bvh = PickAccelerator(mesh)
        let ray = CameraRay.Ray(origin: SIMD3(50.5, 50.5, 5), direction: SIMD3(0, 0, -1))
        let start = Date()
        for _ in 0..<1000 { _ = bvh.pickFace(ray: ray) } // a second of hover events
        // Generous bound: traversal must be far from O(n) per event.
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(bvh.pickFace(ray: ray) != nil)
    }
}
