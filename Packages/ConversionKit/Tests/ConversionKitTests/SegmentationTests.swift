import Testing
import Foundation
@testable import ConversionKit

@Suite("Recolor segmentation + masks")
struct SegmentationTests {
    let segmenter = RecolorSegmenter()

    // Left half red, right half blue (4×2).
    private func twoTone() -> RGBAImage {
        var img = RGBAImage(width: 4, height: 2, fill: (0, 0, 0, 255))
        for y in 0..<2 {
            for x in 0..<4 {
                let c: (UInt8, UInt8, UInt8) = x < 2 ? (220, 30, 30) : (30, 30, 220)
                img.setPixel(x: x, y: y, to: (c.0, c.1, c.2, 255))
            }
        }
        return img
    }

    @Test func clusterSeparatesTwoTones() {
        let img = twoTone()
        let result = segmenter.cluster(img, colorSpace: .sRGB, clusters: 2)
        #expect(result.centers.count == 2)
        // The two left pixels share a label; left differs from right.
        #expect(result.labels[0] == result.labels[1])
        #expect(result.labels[0] != result.labels[2])
    }

    @Test func clusterSingleClusterLabelsAllZero() {
        let img = twoTone()
        let result = segmenter.cluster(img, colorSpace: .sRGB, clusters: 1)
        #expect(result.labels.allSatisfy { $0 == 0 })
    }

    @Test func clusterMaskSelectsClickedRegion() {
        let img = twoTone()
        // Click on the left (red) side.
        let mask = segmenter.clusterMask(img, colorSpace: .sRGB, clusters: 2, atUV: (0.1, 0.5))
        #expect(mask.weight(x: 0, y: 0) == 1)
        #expect(mask.weight(x: 3, y: 0) == 0)
    }

    @Test func similarityMaskThresholdSelectsSimilar() {
        let img = twoTone()
        // Small threshold: only the red side matches a red seed.
        let mask = segmenter.similarityMask(img, colorSpace: .sRGB, atUV: (0.1, 0.5), threshold: 0.1)
        #expect(mask.weight(x: 0, y: 0) == 1)
        #expect(mask.weight(x: 3, y: 0) == 0)
    }

    @Test func similarityMaskFeatherRamps() {
        // Three grays increasing in distance from the seed.
        var img = RGBAImage(width: 3, height: 1, fill: (0, 0, 0, 255))
        img.setPixel(x: 0, y: 0, to: (100, 100, 100, 255))
        img.setPixel(x: 1, y: 0, to: (130, 130, 130, 255))
        img.setPixel(x: 2, y: 0, to: (200, 200, 200, 255))
        let mask = segmenter.similarityMask(img, colorSpace: .sRGB, atUV: (0.0, 0.5),
                                            threshold: 0.02, feather: 0.3)
        #expect(mask.weight(x: 0, y: 0) == 1)                 // seed itself
        let mid = mask.weight(x: 1, y: 0)
        #expect(mid > 0 && mid < 1)                            // in the feather band
        #expect(mask.weight(x: 2, y: 0) == 0)                 // beyond threshold+feather
    }

    @Test func pixelIndexClampsUV() {
        // Out-of-range UVs clamp to the border pixel.
        #expect(segmenter.pixelIndex(forUV: (-1, -1), width: 4, height: 2) == 0)
        #expect(segmenter.pixelIndex(forUV: (2, 2), width: 4, height: 2) == 7)
        #expect(segmenter.pixelIndex(forUV: (0.5, 0.0), width: 4, height: 2) == 2)
    }
}
