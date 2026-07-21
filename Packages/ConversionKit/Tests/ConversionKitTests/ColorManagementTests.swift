import Testing
import Foundation
@testable import ConversionKit

@Suite("Color management + OKLab")
struct ColorManagementTests {

    private func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool {
        abs(a - b) <= eps
    }

    // MARK: - Transfer functions (reference values)

    @Test func sRGBTransferReferenceValues() {
        // Black and white are fixed points.
        #expect(approx(ColorTransfer.sRGBToLinear(0), 0))
        #expect(approx(ColorTransfer.sRGBToLinear(1), 1))
        #expect(approx(ColorTransfer.linearToSRGB(0), 0))
        #expect(approx(ColorTransfer.linearToSRGB(1), 1))
        // Mid-gray 0.5 sRGB → ~0.214 linear (canonical reference value).
        #expect(approx(ColorTransfer.sRGBToLinear(0.5), 0.21404114, 1e-6))
        // Below the knee uses the linear segment.
        #expect(approx(ColorTransfer.sRGBToLinear(0.03), 0.03 / 12.92))
        #expect(approx(ColorTransfer.linearToSRGB(0.002), 0.002 * 12.92))
    }

    @Test func transferRoundTrips() {
        for c in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(approx(ColorTransfer.linearToSRGB(ColorTransfer.sRGBToLinear(c)), c, 1e-9))
        }
    }

    // MARK: - OKLab

    @Test func oklabWhiteAndBlack() {
        let white = OKLab(linear: LinearRGB(r: 1, g: 1, b: 1))
        #expect(approx(white.L, 1, 1e-4))
        #expect(approx(white.a, 0, 1e-4))
        #expect(approx(white.b, 0, 1e-4))
        let black = OKLab(linear: LinearRGB(r: 0, g: 0, b: 0))
        #expect(approx(black.L, 0, 1e-9))
    }

    @Test func oklabRoundTripLinear() {
        let colors = [
            LinearRGB(r: 0.8, g: 0.2, b: 0.1),
            LinearRGB(r: 0.1, g: 0.5, b: 0.9),
            LinearRGB(r: 0.3, g: 0.3, b: 0.3),
        ]
        for c in colors {
            let back = LinearRGB(oklab: OKLab(linear: c))
            #expect(approx(back.r, c.r, 1e-6))
            #expect(approx(back.g, c.g, 1e-6))
            #expect(approx(back.b, c.b, 1e-6))
        }
    }

    @Test func oklchRoundTripAndHueNormalization() {
        // A blue-ish color has a well-defined hue; round-trip through OKLCh.
        let lab = OKLab(linear: LinearRGB(r: 0.1, g: 0.2, b: 0.8))
        let lch = OKLCh(oklab: lab)
        #expect(lch.h >= 0 && lch.h < 2 * .pi)
        #expect(lch.C > 0)
        let back = OKLab(oklch: lch)
        #expect(approx(back.L, lab.L, 1e-9))
        #expect(approx(back.a, lab.a, 1e-9))
        #expect(approx(back.b, lab.b, 1e-9))
    }

    @Test func oklchHueWrapsNegativeIntoRange() {
        // A color with negative atan2 (b<0) must normalize into [0, 2π).
        let lab = OKLab(L: 0.5, a: 0.1, b: -0.1)
        let lch = OKLCh(oklab: lab)
        #expect(lch.h > .pi) // fourth quadrant wraps above π
    }

    // MARK: - CIELab + ΔE

    @Test func cielabWhiteReference() {
        let lab = CIELab(linear: LinearRGB(r: 1, g: 1, b: 1))
        #expect(approx(lab.L, 100, 1e-3))
        #expect(approx(lab.a, 0, 1e-2))
        #expect(approx(lab.b, 0, 1e-2))
    }

    @Test func cielabUsesLinearSegmentForDarkValues() {
        // Very dark input exercises the f() linear branch (t below the knee).
        let lab = CIELab(linear: LinearRGB(r: 0.0005, g: 0.0005, b: 0.0005))
        #expect(lab.L > 0)
        #expect(lab.L < 1)
    }

    @Test func deltaEIdentityAndKnownDistance() {
        let white = CIELab(linear: LinearRGB(r: 1, g: 1, b: 1))
        #expect(approx(deltaE76(white, white), 0))
        let black = CIELab(linear: LinearRGB(r: 0, g: 0, b: 0))
        #expect(approx(deltaE76(white, black), 100, 1e-3))
    }

    // MARK: - Color-space decode/encode

    @Test func decodeEncodeLinearIsPassthrough() {
        let c = ColorManagement.decode((0.3, 0.6, 0.9), from: .linear)
        #expect(approx(c.r, 0.3))
        let enc = ColorManagement.encode(c, to: .linear)
        #expect(approx(enc.r, 0.3))
        #expect(approx(enc.g, 0.6))
        #expect(approx(enc.b, 0.9))
    }

    @Test func decodeEncodeSRGBRoundTrips() {
        let encoded = (r: 0.4, g: 0.5, b: 0.6)
        let linear = ColorManagement.decode(encoded, from: .sRGB)
        // sRGB decode applies the transfer curve.
        #expect(approx(linear.r, ColorTransfer.sRGBToLinear(0.4)))
        let back = ColorManagement.encode(linear, to: .sRGB)
        #expect(approx(back.r, 0.4, 1e-9))
        #expect(approx(back.g, 0.5, 1e-9))
        #expect(approx(back.b, 0.6, 1e-9))
    }

    @Test func decodeEncodeDisplayP3RoundTrips() {
        let encoded = (r: 0.7, g: 0.2, b: 0.5)
        let linear = ColorManagement.decode(encoded, from: .displayP3)
        let back = ColorManagement.encode(linear, to: .displayP3)
        #expect(approx(back.r, 0.7, 1e-6))
        #expect(approx(back.g, 0.2, 1e-6))
        #expect(approx(back.b, 0.5, 1e-6))
    }

    @Test func encodeClampsOutOfGamut() {
        // A linear value above 1 clamps to the encoded ceiling in every space.
        let over = LinearRGB(r: 2, g: -1, b: 0.5)
        let lin = ColorManagement.encode(over, to: .linear)
        #expect(lin.r == 1 && lin.g == 0)
        let srgb = ColorManagement.encode(over, to: .sRGB)
        #expect(srgb.r == 1 && srgb.g == 0)
        let p3 = ColorManagement.encode(LinearRGB(r: 5, g: 5, b: 5), to: .displayP3)
        #expect(p3.r == 1 && p3.g == 1 && p3.b == 1)
    }

    @Test func clamp01Bounds() {
        #expect(ColorManagement.clamp01(-0.2) == 0)
        #expect(ColorManagement.clamp01(1.5) == 1)
        #expect(ColorManagement.clamp01(0.4) == 0.4)
    }

    // MARK: - Hex parsing

    @Test func parseHexAcceptsBothForms() {
        let a = ColorManagement.parseHexSRGB("#FF6B00")
        let b = ColorManagement.parseHexSRGB("ff6b00")
        #expect(a != nil && b != nil)
        #expect(approx(a!.r, 1))
        #expect(approx(a!.g, Double(0x6B) / 255))
        #expect(approx(a!.b, 0))
        #expect(a! == b!)
    }

    @Test func parseHexRejectsMalformed() {
        #expect(ColorManagement.parseHexSRGB("#FFF") == nil)      // too short
        #expect(ColorManagement.parseHexSRGB("GGGGGG") == nil)    // non-hex
        #expect(ColorManagement.parseHexSRGB("#1234567") == nil)  // too long
    }

    @Test func textureColorSpaceIsCodable() throws {
        for space in TextureColorSpace.allCases {
            let data = try JSONEncoder().encode(space)
            let back = try JSONDecoder().decode(TextureColorSpace.self, from: data)
            #expect(back == space)
        }
    }
}
