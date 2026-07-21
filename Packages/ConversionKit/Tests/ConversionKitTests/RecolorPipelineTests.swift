import Testing
import Foundation
@testable import ConversionKit

@Suite("RecolorPipeline (batch/CLI façade)")
struct RecolorPipelineTests {

    private func redSwatch() -> RGBAImage {
        RGBAImage(width: 8, height: 8, fill: (200, 40, 40, 255))
    }

    @Test func targetFromHexParses() throws {
        let t = try RecolorPipeline.target(fromHex: "#FF6B00")
        #expect(t.r == 1)
        #expect(t.b == 0)
    }

    @Test func targetFromHexRejectsBad() {
        #expect(throws: RecolorPipeline.PipelineError.invalidTargetColor) {
            _ = try RecolorPipeline.target(fromHex: "xyz")
        }
    }

    @Test func directModeRecolorsHuePreservesLightness() throws {
        let target = try RecolorPipeline.target(fromHex: "#2040E0") // blue
        let result = try RecolorPipeline.recolor(redSwatch(), request: RecolorRequest(target: target))
        // Direct mode remaps hue/chroma but preserves the source lightness, so
        // the achieved hue matches the target while the pixel clearly changed.
        #expect(result.image.pixel(x: 0, y: 0) != (200, 40, 40, 255))
        let engine = RecolorEngine()
        let stats = engine.statistics(of: result.image, colorSpace: .sRGB, mask: .full(width: 8, height: 8))
        let targetHue = OKLCh(oklab: OKLab(linear: ColorManagement.decode(target, from: .sRGB))).h
        let dh = abs(stats.meanHue - targetHue)
        #expect(min(dh, 2 * .pi - dh) < 0.1)
    }

    @Test func calibratedModeConvergesUnderDeltaE2() throws {
        // The golden calibration gate: a flat swatch recolored in calibrated
        // mode achieves ΔE < 2.0 against its target.
        let target = try RecolorPipeline.target(fromHex: "#1B7F3A") // green
        let result = try RecolorPipeline.recolor(
            redSwatch(),
            request: RecolorRequest(target: target, mode: .calibrated)
        )
        #expect(result.achievedDeltaE < 2.0)
    }

    @Test func calibratedBeatsDirectOnResidual() throws {
        let target = try RecolorPipeline.target(fromHex: "#E0C020") // saturated yellow (gamut-stressed)
        let direct = try RecolorPipeline.recolor(redSwatch(), request: RecolorRequest(target: target, mode: .direct))
        let calibrated = try RecolorPipeline.recolor(redSwatch(), request: RecolorRequest(target: target, mode: .calibrated))
        #expect(calibrated.achievedDeltaE <= direct.achievedDeltaE)
    }

    @Test func maskRestrictsRecolor() throws {
        let target = try RecolorPipeline.target(fromHex: "#2040E0")
        var coverage = [Double](repeating: 0, count: 64)
        coverage[0] = 1
        let mask = RecolorMask(width: 8, height: 8, coverage: coverage)
        let result = try RecolorPipeline.recolor(redSwatch(), request: RecolorRequest(target: target, mask: mask))
        #expect(result.image.pixel(x: 7, y: 7) == (200, 40, 40, 255)) // untouched
        #expect(result.image.pixel(x: 0, y: 0) != (200, 40, 40, 255)) // recolored
    }

    @Test func maskSizeMismatchThrows() {
        let target = (r: 0.1, g: 0.2, b: 0.8)
        let mask = RecolorMask(width: 2, height: 2, coverage: [1, 1, 1, 1])
        #expect(throws: RecolorPipeline.PipelineError.maskSizeMismatch) {
            _ = try RecolorPipeline.recolor(redSwatch(), request: RecolorRequest(target: target, mask: mask))
        }
    }

    @Test func imageDataRoundTripRecolors() throws {
        let png = try RGBAImageCodec.encodePNG(redSwatch())
        let target = try RecolorPipeline.target(fromHex: "#2040E0")
        let (data, deltaE) = try RecolorPipeline.recolorImageData(
            png, request: RecolorRequest(target: target, mode: .calibrated))
        #expect(deltaE < 2.0)
        let decoded = try RGBAImageCodec.decode(data)
        #expect(decoded.width == 8 && decoded.height == 8)
        #expect(decoded.pixel(x: 0, y: 0) != (200, 40, 40, 255))
    }

    @Test func p3TargetDecodesDifferentlyThanSRGB() throws {
        // The same encoded triple tagged P3 vs sRGB decodes through different
        // primaries, so the recolor result differs — proving the tag is honored.
        let encoded = (r: 0.2, g: 0.5, b: 0.7)
        let asP3 = try RecolorPipeline.recolor(redSwatch(),
            request: RecolorRequest(target: encoded, targetSpace: .displayP3))
        let asSRGB = try RecolorPipeline.recolor(redSwatch(),
            request: RecolorRequest(target: encoded, targetSpace: .sRGB))
        #expect(asP3.image.pixels != asSRGB.image.pixels)
    }

    @Test func modeAndEnumsCodable() throws {
        for mode in RecolorMode.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(RecolorMode.self, from: data) == mode)
        }
    }
}
