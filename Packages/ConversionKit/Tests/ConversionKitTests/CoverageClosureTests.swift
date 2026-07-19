import Testing
import Foundation
import simd
import USDCore
@testable import ConversionKit

@Suite("ConversionKit coverage closure")
struct ConversionKitCoverageClosureTests {

    // MARK: BatchConverter default (real-FileManager) closures

    @Test func defaultWriteAndExistsClosuresTouchRealDisk() async throws {
        let glb = try GLTFFixtures.write(
            GLTFFixtures.glb(json: GLTFFixtures.triangleJSON(), bin: GLTFFixtures.triangleBIN()),
            name: "tri.glb")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)/tri.usda")
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }

        // No injected fileExists/writeFile → exercises the default closures.
        let report = await BatchConverter().run([BatchJob(input: glb, output: out)])
        #expect(report.succeededCount == 1)
        #expect(FileManager.default.fileExists(atPath: out.path))

        // overwrite=false + a now-existing output → default fileExists → skipped.
        let second = await BatchConverter(overwrite: false).run([BatchJob(input: glb, output: out)])
        #expect(second.items.first?.status == .skipped)
    }

    // MARK: AnimationSampler resampling math

    @Test func sampledQuatTakesShortestPathAcrossSignFlip() {
        // q0 and q1 point to opposite hemispheres (dot < 0); the blend must flip
        // q1's sign so the interpolation goes the short way.
        let q0 = SIMD4<Float>(0, 0, 0, 1)
        let q1 = SIMD4<Float>(0, 0, 0, -1)
        let sampler = AnimationSampler(input: [0, 1], interpolation: .linear, output: .rotation([q0, q1]))
        let mid = sampler.sampledQuat(at: 0.5)
        let m = try! #require(mid)
        // Shortest path from (0,0,0,1) to its negation stays near w=±1, not through 0.
        #expect(abs(abs(m.w) - 1) < 1e-5)
    }

    @Test func sampledVec3InterpolatesInteriorKey() {
        let sampler = AnimationSampler(
            input: [0, 2], interpolation: .linear,
            output: .vec3([SIMD3(0, 0, 0), SIMD3(2, 4, 6)]))
        let v = try! #require(sampler.sampledVec3(at: 1))  // exactly halfway
        #expect(abs(v.x - 1) < 1e-5 && abs(v.y - 2) < 1e-5 && abs(v.z - 3) < 1e-5)
    }

    @Test func sampledValuesClampAtEnds() {
        let sampler = AnimationSampler(
            input: [0, 1], interpolation: .linear,
            output: .vec3([SIMD3(1, 1, 1), SIMD3(9, 9, 9)]))
        #expect(sampler.sampledVec3(at: -5)?.x == 1)   // before first key
        #expect(sampler.sampledVec3(at: 5)?.x == 9)    // after last key
    }

    @Test func stepInterpolationHoldsKey() {
        let sampler = AnimationSampler(
            input: [0, 1], interpolation: .step,
            output: .rotation([SIMD4(0, 0, 0, 1), SIMD4(0, 1, 0, 0)]))
        let q = try! #require(sampler.sampledQuat(at: 0.3))
        #expect(abs(q.w - 1) < 1e-5)  // holds the first key, no blend
    }

    @Test func emptyRotationOutputYieldsNil() {
        let sampler = AnimationSampler(input: [], interpolation: .linear, output: .rotation([]))
        #expect(sampler.sampledQuat(at: 0) == nil)
    }
}
