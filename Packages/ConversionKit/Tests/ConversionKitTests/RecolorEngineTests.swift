import Testing
import Foundation
@testable import ConversionKit

@Suite("RecolorEngine (CPU reference)")
struct RecolorEngineTests {
    let engine = RecolorEngine()

    // A 4×4 image: solid red-ish base with a little per-pixel lightness grain,
    // so "detail preservation" is observable.
    private func grainyImage(base: (UInt8, UInt8, UInt8)) -> RGBAImage {
        var img = RGBAImage(width: 4, height: 4, fill: (base.0, base.1, base.2, 255))
        for y in 0..<4 {
            for x in 0..<4 {
                let jitter = Int8(truncatingIfNeeded: (x + y) * 5 - 15)
                let r = UInt8(clamping: Int(base.0) + Int(jitter))
                img.setPixel(x: x, y: y, to: (r, base.1, base.2, 255))
            }
        }
        return img
    }

    @Test func imageBufferAccessors() {
        var img = RGBAImage(width: 2, height: 2, fill: (10, 20, 30, 40))
        #expect(img.pixelCount == 4)
        #expect(img.pixel(x: 1, y: 1) == (10, 20, 30, 40))
        img.setPixel(x: 0, y: 0, to: (1, 2, 3, 4))
        #expect(img.pixel(x: 0, y: 0) == (1, 2, 3, 4))
        let explicit = RGBAImage(width: 1, height: 1, pixels: [5, 6, 7, 8])
        #expect(explicit.pixel(x: 0, y: 0) == (5, 6, 7, 8))
    }

    @Test func maskFullAndWeights() {
        let mask = RecolorMask.full(width: 3, height: 2)
        #expect(mask.weight(x: 2, y: 1) == 1)
        let partial = RecolorMask(width: 2, height: 1, coverage: [0.25, 0.75])
        #expect(partial.weight(x: 0, y: 0) == 0.25)
        #expect(partial.weight(x: 1, y: 0) == 0.75)
    }

    @Test func statisticsOverFullMask() {
        let img = grainyImage(base: (200, 40, 40))
        let stats = engine.statistics(of: img, colorSpace: .sRGB, mask: .full(width: 4, height: 4))
        #expect(stats.weight == 16)
        #expect(stats.meanChroma > 0)
        #expect(stats.meanHue >= 0 && stats.meanHue < 2 * .pi)
        #expect(stats.meanLightness > 0)
    }

    @Test func statisticsEmptyMaskIsZero() {
        let img = RGBAImage(width: 2, height: 2, fill: (100, 100, 100, 255))
        let mask = RecolorMask(width: 2, height: 2, coverage: [0, 0, 0, 0])
        let stats = engine.statistics(of: img, colorSpace: .sRGB, mask: mask)
        #expect(stats.weight == 0)
        #expect(stats.meanHue == 0)
        #expect(stats.meanChroma == 0)
    }

    @Test func recolorChangesHueTowardTarget() {
        let img = grainyImage(base: (200, 40, 40)) // red
        // Target a blue hue.
        let target = OKLCh(oklab: OKLab(linear: ColorManagement.decode((0.1, 0.2, 0.9), from: .sRGB)))
        let params = RecolorParameters(target: target)
        let out = engine.recolor(img, colorSpace: .sRGB, parameters: params, mask: .full(width: 4, height: 4))
        let outStats = engine.statistics(of: out, colorSpace: .sRGB, mask: .full(width: 4, height: 4))
        // Output mean hue is near the target hue.
        let dh = abs(outStats.meanHue - target.h)
        #expect(min(dh, 2 * .pi - dh) < 0.15)
    }

    @Test func recolorPreservesLightnessVariation() {
        let img = grainyImage(base: (200, 40, 40))
        let target = OKLCh(oklab: OKLab(linear: ColorManagement.decode((0.1, 0.2, 0.9), from: .sRGB)))
        let out = engine.recolor(img, colorSpace: .sRGB, parameters: RecolorParameters(target: target),
                                 mask: .full(width: 4, height: 4))
        // The grain (per-pixel lightness spread) survives: not a flat patch.
        var lightnesses = Set<Int>()
        for y in 0..<4 {
            for x in 0..<4 {
                let lab = OKLab(linear: ColorManagement.decode(
                    { let p = out.pixel(x: x, y: y); return (Double(p.r) / 255, Double(p.g) / 255, Double(p.b) / 255) }(),
                    from: .sRGB))
                lightnesses.insert(Int((lab.L * 1000).rounded()))
            }
        }
        #expect(lightnesses.count > 1)
    }

    @Test func recolorToSameStatsIsApproxIdentity() {
        // Property: recoloring toward the region's own mean hue/chroma with full
        // preservation reproduces the input within a tight ΔE.
        let img = grainyImage(base: (120, 160, 80))
        let stats = engine.statistics(of: img, colorSpace: .sRGB, mask: .full(width: 4, height: 4))
        let params = RecolorParameters(targetHue: stats.meanHue, targetChroma: stats.meanChroma,
                                       preserveHueVariation: true)
        let out = engine.recolor(img, colorSpace: .sRGB, parameters: params, mask: .full(width: 4, height: 4))
        #expect(engine.meanDeltaE76(img, out, colorSpace: .sRGB) < 1.0)
    }

    @Test func zeroCoverageLeavesPixelsUntouched() {
        let img = grainyImage(base: (200, 40, 40))
        // Mask selects only the top-left pixel.
        var coverage = [Double](repeating: 0, count: 16)
        coverage[0] = 1
        let mask = RecolorMask(width: 4, height: 4, coverage: coverage)
        let target = OKLCh(oklab: OKLab(linear: ColorManagement.decode((0.1, 0.2, 0.9), from: .sRGB)))
        let out = engine.recolor(img, colorSpace: .sRGB, parameters: RecolorParameters(target: target), mask: mask)
        // Untouched pixel identical; masked pixel changed.
        #expect(out.pixel(x: 3, y: 3) == img.pixel(x: 3, y: 3))
        #expect(out.pixel(x: 0, y: 0) != img.pixel(x: 0, y: 0))
    }

    @Test func partialCoverageFeathersBetween() {
        let img = RGBAImage(width: 1, height: 1, fill: (200, 40, 40, 255))
        let target = OKLCh(oklab: OKLab(linear: ColorManagement.decode((0.1, 0.2, 0.9), from: .sRGB)))
        let full = engine.recolor(img, colorSpace: .sRGB, parameters: RecolorParameters(target: target),
                                  mask: RecolorMask(width: 1, height: 1, coverage: [1]))
        let half = engine.recolor(img, colorSpace: .sRGB, parameters: RecolorParameters(target: target),
                                  mask: RecolorMask(width: 1, height: 1, coverage: [0.5]))
        // Half-coverage lands between original and fully recolored.
        #expect(half.pixel(x: 0, y: 0) != full.pixel(x: 0, y: 0))
        #expect(half.pixel(x: 0, y: 0) != img.pixel(x: 0, y: 0))
    }

    @Test func lightnessBiasBrightens() {
        let img = RGBAImage(width: 1, height: 1, fill: (120, 60, 60, 255))
        let target = OKLCh(oklab: OKLab(linear: ColorManagement.decode((0.3, 0.3, 0.7), from: .sRGB)))
        let brighter = engine.recolor(img, colorSpace: .sRGB,
            parameters: RecolorParameters(target: target, lightnessBias: 0.2),
            mask: .full(width: 1, height: 1))
        let neutral = engine.recolor(img, colorSpace: .sRGB,
            parameters: RecolorParameters(target: target),
            mask: .full(width: 1, height: 1))
        let lb = OKLab(linear: ColorManagement.decode({ let p = brighter.pixel(x: 0, y: 0); return (Double(p.r)/255, Double(p.g)/255, Double(p.b)/255) }(), from: .sRGB)).L
        let ln = OKLab(linear: ColorManagement.decode({ let p = neutral.pixel(x: 0, y: 0); return (Double(p.r)/255, Double(p.g)/255, Double(p.b)/255) }(), from: .sRGB)).L
        #expect(lb > ln)
    }

    @Test func chromaPreservationZeroFlattens() {
        // With preservation 0, per-pixel chroma collapses toward the target.
        let img = grainyImage(base: (200, 40, 40))
        let target = OKLCh(oklab: OKLab(linear: ColorManagement.decode((0.1, 0.2, 0.9), from: .sRGB)))
        let out = engine.recolor(img, colorSpace: .sRGB,
            parameters: RecolorParameters(target: target, chromaPreservation: 0),
            mask: .full(width: 4, height: 4))
        var chromas = Set<Int>()
        for y in 0..<4 {
            for x in 0..<4 {
                let lch = OKLCh(oklab: OKLab(linear: ColorManagement.decode(
                    { let p = out.pixel(x: x, y: y); return (Double(p.r)/255, Double(p.g)/255, Double(p.b)/255) }(),
                    from: .sRGB)))
                chromas.insert(Int((lch.C * 100).rounded()))
            }
        }
        // Chroma is (near) uniform; lightness grain still varies it a touch, so
        // allow a small spread but far less than the preserved case.
        #expect(chromas.count <= 3)
    }

    @Test func preserveHueVariationKeepsSpread() {
        // Two-tone image: half red, half orange.
        var img = RGBAImage(width: 2, height: 1, fill: (200, 40, 40, 255))
        img.setPixel(x: 1, y: 0, to: (200, 120, 40, 255))
        let target = OKLCh(oklab: OKLab(linear: ColorManagement.decode((0.1, 0.2, 0.9), from: .sRGB)))
        let varied = engine.recolor(img, colorSpace: .sRGB,
            parameters: RecolorParameters(target: target, preserveHueVariation: true),
            mask: .full(width: 2, height: 1))
        let h0 = OKLCh(oklab: OKLab(linear: ColorManagement.decode({ let p = varied.pixel(x:0,y:0); return (Double(p.r)/255,Double(p.g)/255,Double(p.b)/255) }(), from: .sRGB))).h
        let h1 = OKLCh(oklab: OKLab(linear: ColorManagement.decode({ let p = varied.pixel(x:1,y:0); return (Double(p.r)/255,Double(p.g)/255,Double(p.b)/255) }(), from: .sRGB))).h
        #expect(abs(h0 - h1) > 0.001)
    }

    @Test func meanDeltaEIdentical() {
        let img = grainyImage(base: (100, 100, 100))
        #expect(engine.meanDeltaE76(img, img, colorSpace: .sRGB) == 0)
    }
}
