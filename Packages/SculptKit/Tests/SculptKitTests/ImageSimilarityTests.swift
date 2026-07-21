import Foundation
import Testing
@testable import SculptKit

/// Covers the deterministic reference-vs-render similarity metric — the
/// verifiable floor under the subjective review score.
@Suite struct ImageSimilarityTests {

    /// Build a `w×h` RGBA image by sampling a per-pixel colour closure.
    static func image(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> RasterImage {
        var bytes = [UInt8](); bytes.reserveCapacity(w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b, a) = pixel(x, y)
                bytes += [r, g, b, a]
            }
        }
        return RasterImage(width: w, height: h, rgba: bytes)!
    }

    /// A solid opaque colour filling the frame.
    static func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, a: UInt8 = 255) -> RasterImage {
        image(w, h) { _, _ in (r, g, b, a) }
    }

    /// A centered opaque square of `side` on a transparent field (alpha cutout).
    static func square(_ dim: Int, side: Int, color: UInt8 = 200) -> RasterImage {
        let lo = (dim - side) / 2, hi = lo + side
        return image(dim, dim) { x, y in
            (x >= lo && x < hi && y >= lo && y < hi) ? (color, color, color, 255) : (0, 0, 0, 0)
        }
    }

    // MARK: - RasterImage validation

    @Test func rejectsMalformedBuffers() {
        #expect(RasterImage(width: 0, height: 4, rgba: []) == nil)
        #expect(RasterImage(width: 2, height: 2, rgba: [0, 0, 0]) == nil)   // wrong length
        #expect(RasterImage(width: 1, height: 1, rgba: [1, 2, 3, 4]) != nil)
    }

    // MARK: - Identical inputs

    @Test func identicalImagesScoreOne() {
        let img = Self.square(64, side: 32)
        let report = ImageSimilarity.compare(reference: img, render: img)
        #expect(report.silhouetteIoU == 1)
        #expect(abs(report.ssim - 1) < 1e-6)
        #expect(report.aggregate > 0.99)
    }

    @Test func identicalSolidOpaqueImagesScoreOne() {
        // No meaningful alpha → colour-key foreground path (corner = bg).
        let img = Self.solid(48, 48, 180, 40, 40)
        let report = ImageSimilarity.compare(reference: img, render: img)
        #expect(abs(report.ssim - 1) < 1e-6)
        #expect(report.luminanceCorrelation >= 0.999)   // flat field → mean-gap fallback = 1
        #expect(report.aggregate > 0.99)
    }

    // MARK: - Divergent inputs

    @Test func disjointSilhouettesScoreLow() {
        // A small square vs a big square: partial overlap, lower IoU.
        let small = Self.square(64, side: 16)
        let big = Self.square(64, side: 56)
        let report = ImageSimilarity.compare(reference: small, render: big)
        #expect(report.silhouetteIoU < 0.35)
        #expect(report.aggregate < small.pipelineAggregateCeiling)
    }

    @Test func wrongShapeFailsFloor() {
        // Reference is a centered square; render is empty (all background).
        let ref = Self.square(64, side: 40)
        let empty = Self.solid(64, 64, 0, 0, 0, a: 0)
        let report = ImageSimilarity.compare(reference: ref, render: empty)
        // No overlap at all → IoU 0, aggregate well below any sane floor.
        #expect(report.silhouetteIoU == 0)
        #expect(report.aggregate < 0.5)
    }

    @Test func bothEmptySilhouettesTriviallyAgree() {
        let empty = Self.solid(32, 32, 0, 0, 0, a: 0)
        // Two fully-transparent frames: union is empty → IoU defined as 1.
        let report = ImageSimilarity.compare(reference: empty, render: empty)
        #expect(report.silhouetteIoU == 1)
    }

    @Test func differentResolutionsCompareCleanly() {
        let a = Self.square(64, side: 32)
        let b = Self.square(128, side: 64)   // same relative shape, 2× resolution
        let report = ImageSimilarity.compare(reference: a, render: b)
        #expect(report.silhouetteIoU > 0.9)
        #expect(report.aggregate > 0.9)
    }

    // MARK: - Luminance correlation branches

    @Test func luminanceCorrelationRewardsMatchingGradients() {
        let dim = 32
        let ramp = Self.image(dim, dim) { x, _ in
            let v = UInt8(x * 255 / (dim - 1)); return (v, v, v, 255)
        }
        let same = ImageSimilarity.compare(reference: ramp, render: ramp)
        #expect(same.luminanceCorrelation > 0.99)

        // Inverted ramp → negative correlation → remapped toward 0.
        let inverted = Self.image(dim, dim) { x, _ in
            let v = UInt8((dim - 1 - x) * 255 / (dim - 1)); return (v, v, v, 255)
        }
        let opposed = ImageSimilarity.compare(reference: ramp, render: inverted)
        #expect(opposed.luminanceCorrelation < 0.05)
    }

    @Test func flatFieldsUseMeanGapFallback() {
        // Both flat but different brightness → correlation undefined → fallback
        // 1 - |Δmean|. White vs mid-grey opaque fields.
        let white = Self.solid(16, 16, 255, 255, 255)
        let grey = Self.solid(16, 16, 128, 128, 128)
        let report = ImageSimilarity.compare(reference: white, render: grey)
        #expect(report.luminanceCorrelation > 0.4)
        #expect(report.luminanceCorrelation < 0.6)
    }

    // MARK: - Worst-view aggregation

    @Test func worstViewReturnsMinimumAggregate() {
        let good = Self.square(64, side: 32)
        let bad = Self.solid(64, 64, 0, 0, 0, a: 0)
        let ref = Self.square(64, side: 32)
        let worst = ImageSimilarity.worstView([(ref, good), (ref, bad)])
        #expect(worst != nil)
        // The empty render drags the worst-view score down.
        #expect(worst!.silhouetteIoU == 0)
    }

    @Test func worstViewEmptyIsNil() {
        #expect(ImageSimilarity.worstView([]) == nil)
    }

    @Test func worstViewSinglePairIsThatPair() {
        let img = Self.square(64, side: 24)
        let one = ImageSimilarity.worstView([(img, img)])
        #expect(one?.silhouetteIoU == 1)
    }

    // MARK: - Monotonicity ("verifiably better")

    /// The core guarantee the deterministic floor rests on: a render whose
    /// silhouette is closer to the reference scores strictly higher than one
    /// that is further off. This is what makes "it got better" a number, not a
    /// vibe — regressing it would break the fidelity gate's meaning.
    @Test func closerRenderScoresStrictlyHigher() {
        let reference = Self.square(64, side: 32)
        let close = Self.square(64, side: 30)     // nearly the same size
        let far = Self.square(64, side: 12)       // much smaller
        let closeReport = ImageSimilarity.compare(reference: reference, render: close)
        let farReport = ImageSimilarity.compare(reference: reference, render: far)
        #expect(closeReport.aggregate > farReport.aggregate)
        #expect(closeReport.silhouetteIoU > farReport.silhouetteIoU)
    }

    @Test func aggregateIsMonotonicAcrossAShrinkingSweep() {
        let reference = Self.square(96, side: 48)
        // Renders that progressively diverge from the reference size.
        let sides = [48, 40, 32, 24, 16, 8]
        let scores = sides.map { ImageSimilarity.compare(
            reference: reference, render: Self.square(96, side: $0)).aggregate }
        // Each further-off render scores no higher than the previous, closer one.
        for i in 1..<scores.count {
            #expect(scores[i] <= scores[i - 1] + 1e-9)
        }
        #expect(scores.first! > scores.last!)   // and the sweep genuinely spans a range
    }

    // MARK: - SimilarityReport codable

    @Test func reportRoundTrips() throws {
        let report = SimilarityReport(silhouetteIoU: 0.8, luminanceCorrelation: 0.7, ssim: 0.6,
                                      shapeScore: 0.82, appearanceScore: 0.65, aggregate: 0.75)
        let data = try JSONEncoder().encode(report)
        let back = try JSONDecoder().decode(SimilarityReport.self, from: data)
        #expect(back == report)
    }
}

private extension RasterImage {
    /// Small helper so the disjoint-silhouette assertion reads intentionally:
    /// the aggregate must land below what a good match would score.
    var pipelineAggregateCeiling: Double { 0.85 }
}
