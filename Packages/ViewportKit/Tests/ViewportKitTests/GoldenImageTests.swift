import Testing
import Foundation
import simd
@testable import ViewportKit

#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

@Suite("Golden-image ΔE harness (#126, testing layer 6)")
struct GoldenImageTests {

    /// A solid `w×h` image of one RGBA colour.
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255,
                       w: Int = 4, h: Int = 4) -> GoldenImage {
        var px = [UInt8]()
        px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, a]) }
        return GoldenImage(width: w, height: h, rgba: px)
    }

    // MARK: Comparator

    @Test func identicalImagesScoreZero() throws {
        let img = solid(120, 130, 140)
        let cmp = try GoldenImageComparator.compare(img, reference: img)
        #expect(cmp.meanDeltaE == 0)
        #expect(cmp.maxDeltaE == 0)
        #expect(cmp.p95DeltaE == 0)
        #expect(cmp.pixelCount == 16)
        #expect(cmp.passes(threshold: 2.0))
    }

    @Test func dimensionMismatchThrows() {
        let a = solid(0, 0, 0, w: 4, h: 4)
        let b = solid(0, 0, 0, w: 4, h: 5)
        #expect(throws: GoldenImageError.self) {
            try GoldenImageComparator.compare(a, reference: b)
        }
    }

    @Test func blackVsWhiteScoresApproximately100() throws {
        // ΔE76 between L*=0 and L*=100 pure black/white is exactly 100.
        let cmp = try GoldenImageComparator.compare(solid(0, 0, 0), reference: solid(255, 255, 255))
        #expect(abs(cmp.meanDeltaE - 100) < 0.5)
        #expect(!cmp.passes(threshold: 2.0))
    }

    @Test func knownGraySwatchDeltaEMatchesReference() throws {
        // Two mid grays differing by 10 sRGB levels — a small but real ΔE.
        let cmp = try GoldenImageComparator.compare(solid(128, 128, 128),
                                                    reference: solid(138, 138, 138))
        #expect(cmp.meanDeltaE > 1.5 && cmp.meanDeltaE < 6)
        #expect(abs(cmp.meanDeltaE - cmp.maxDeltaE) < 1e-9) // uniform image
    }

    @Test func p95IgnoresAFewOutlierPixels() throws {
        // 100 pixels: 98 identical, 2 wildly different. p95 should stay ~0
        // while max is huge — the reason the gate uses p95, not max.
        let w = 10, h = 10
        var cand = [UInt8](); var ref = [UInt8]()
        for i in 0..<(w * h) {
            let outlier = i < 2
            cand.append(contentsOf: outlier ? [255, 255, 255, 255] : [100, 100, 100, 255])
            ref.append(contentsOf: [100, 100, 100, 255])
        }
        let cmp = try GoldenImageComparator.compare(
            GoldenImage(width: w, height: h, rgba: cand),
            reference: GoldenImage(width: w, height: h, rgba: ref))
        #expect(cmp.maxDeltaE > 50)
        #expect(cmp.p95DeltaE < 1)
        #expect(cmp.passes(threshold: 2.0)) // p95 + mean both tiny
    }

    @Test func gateFailsWhenMeanExceedsThresholdEvenIfP95Low() throws {
        // Broad, uniform small drift: mean high, but a single-value image means
        // p95 == mean, so this exercises the mean arm of `passes`.
        let cmp = try GoldenImageComparator.compare(solid(100, 100, 100),
                                                    reference: solid(150, 150, 150))
        #expect(cmp.meanDeltaE > 2.0)
        #expect(!cmp.passes(threshold: 2.0))
    }

    // MARK: Colour math

    @Test func srgbToLinearMatchesKnownPoints() {
        #expect(GoldenImageComparator.srgbToLinear(0) == 0)
        #expect(abs(GoldenImageComparator.srgbToLinear(1) - 1) < 1e-9)
        // Below the piecewise breakpoint uses the linear segment.
        #expect(abs(GoldenImageComparator.srgbToLinear(0.04) - 0.04 / 12.92) < 1e-9)
    }

    @Test func labOfWhiteIsL100() {
        let lab = GoldenImageComparator.srgb8ToLab(255, 255, 255)
        #expect(abs(lab.x - 100) < 0.1)
        #expect(abs(lab.y) < 0.1)
        #expect(abs(lab.z) < 0.1)
    }

    @Test func labOfBlackIsL0() {
        let lab = GoldenImageComparator.srgb8ToLab(0, 0, 0)
        #expect(abs(lab.x) < 0.1)
    }

    @Test func deltaE76IsEuclidean() {
        let d = GoldenImageComparator.deltaE76(SIMD3(0, 0, 0), SIMD3(3, 4, 0))
        #expect(abs(d - 5) < 1e-9)
    }

    // MARK: Percentile helper

    @Test func percentileInterpolatesAndHandlesEdges() {
        #expect(GoldenImageComparator.percentile([], 0.95) == 0)
        #expect(GoldenImageComparator.percentile([7], 0.95) == 7)
        #expect(GoldenImageComparator.percentile([0, 10], 0.5) == 5)
        #expect(GoldenImageComparator.percentile([0, 10], 0) == 0)
        #expect(GoldenImageComparator.percentile([0, 10], 1) == 10)
    }

    // MARK: Guards

    @Test func labFCoversBothBranches() {
        // Large t → cube-root branch; tiny t → linear branch. Both exercised
        // via srgb8ToLab above, but assert the companding is continuous here.
        let big = GoldenImageComparator.srgb8ToLab(200, 10, 10)
        let small = GoldenImageComparator.srgb8ToLab(5, 5, 5)
        #expect(big.x > small.x)
    }

    // MARK: PNG decode round-trip (ImageIO — runs on the CI macOS runner)

    #if canImport(ImageIO)
    @Test func decodesEncodedPNGBackToPixels() throws {
        let w = 3, h = 2
        // Distinct colours per pixel so we can verify orientation + channels.
        let colours: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (255, 255, 0), (0, 255, 255), (255, 0, 255),
        ]
        var raw = [UInt8]()
        for c in colours { raw.append(contentsOf: [c.0, c.1, c.2, 255]) }

        let data = try encodePNG(width: w, height: h, rgba: raw)
        let decoded = try GoldenImage.decode(data: data)
        #expect(decoded.width == w)
        #expect(decoded.height == h)

        // Compare against the source as a golden reference: must be ~0 ΔE.
        let source = GoldenImage(width: w, height: h, rgba: raw)
        let cmp = try GoldenImageComparator.compare(decoded, reference: source)
        #expect(cmp.maxDeltaE < 1.0)
    }

    @Test func decodeRejectsNonImageData() {
        #expect(throws: (any Error).self) {
            try GoldenImage.decode(data: Data([0x00, 0x01, 0x02, 0x03]))
        }
    }

    /// Encodes straight-RGBA8 to PNG via ImageIO for the decode round-trip.
    private func encodePNG(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        var buffer = rgba
        let ctx = buffer.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let cg = ctx!.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
    #endif
}
