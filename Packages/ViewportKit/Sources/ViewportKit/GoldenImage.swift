import Foundation
import simd

// The T1 golden-image ΔE harness core (specs/testing.md layer 6, GitHub #126).
//
// The *production* of a candidate frame is a GPU step (offscreen viewport
// render) that runs locally / nightly, but the part that decides pass/fail —
// the perceptual ΔE comparison against a committed reference PNG — is pure and
// runs per-PR in CI. Keeping it GPU-free means the gate itself is unit-tested
// and deterministic: identical images score 0, and a known swatch pair scores a
// known CIELAB ΔE. This mirrors how the ConversionKit recolor path is gated by
// a pure `meanDeltaE76` reference while its Metal kernel stays excluded.

/// A decoded, straight-alpha RGBA8 image the harness compares. Row-major, 4
/// bytes per pixel, top-left origin — the same layout as ``DebugTexture``.
public struct GoldenImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, R,G,B,A per pixel.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width > 0 && height > 0, "image must be non-empty")
        precondition(rgba.count == width * height * 4,
                     "rgba length must be width*height*4")
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// The result of comparing a candidate frame to its reference.
public struct GoldenImageComparison: Equatable, Sendable {
    /// Mean CIELAB ΔE76 across all compared pixels.
    public let meanDeltaE: Double
    /// Worst single-pixel ΔE — catches a small but glaring local regression a
    /// mean would wash out.
    public let maxDeltaE: Double
    /// 95th-percentile ΔE — the gate value of choice: robust to a handful of
    /// antialiased edge pixels while still catching broad drift.
    public let p95DeltaE: Double
    /// Number of pixels compared.
    public let pixelCount: Int

    /// Whether this comparison passes a gate: both the 95th-percentile and mean
    /// ΔE are within `threshold`. (Max is reported for triage, not gated, so a
    /// single resampled edge pixel can't fail an otherwise-perfect frame.)
    public func passes(threshold: Double) -> Bool {
        p95DeltaE <= threshold && meanDeltaE <= threshold
    }
}

/// Errors the comparator raises before it can score.
public enum GoldenImageError: Error, Equatable, Sendable {
    /// The two images differ in pixel dimensions (`.x` = width, `.y` = height).
    case dimensionMismatch(candidate: SIMD2<Int>, reference: SIMD2<Int>)
}

/// Pure perceptual comparison of two images. GPU-free and deterministic.
public enum GoldenImageComparator {

    /// Compares `candidate` against `reference`, returning per-frame ΔE
    /// statistics. Throws ``GoldenImageError/dimensionMismatch`` if their
    /// dimensions differ (a size change is always a re-baseline, never a pass).
    public static func compare(_ candidate: GoldenImage,
                               reference: GoldenImage) throws -> GoldenImageComparison {
        guard candidate.width == reference.width,
              candidate.height == reference.height else {
            throw GoldenImageError.dimensionMismatch(
                candidate: SIMD2(candidate.width, candidate.height),
                reference: SIMD2(reference.width, reference.height))
        }

        let count = candidate.width * candidate.height
        var deltas = [Double](repeating: 0, count: count)
        var sum = 0.0
        var maxD = 0.0
        for i in 0..<count {
            let o = i * 4
            let labA = srgb8ToLab(candidate.rgba[o], candidate.rgba[o + 1], candidate.rgba[o + 2])
            let labB = srgb8ToLab(reference.rgba[o], reference.rgba[o + 1], reference.rgba[o + 2])
            let d = deltaE76(labA, labB)
            deltas[i] = d
            sum += d
            if d > maxD { maxD = d }
        }

        let mean = count > 0 ? sum / Double(count) : 0
        return GoldenImageComparison(
            meanDeltaE: mean,
            maxDeltaE: maxD,
            p95DeltaE: percentile(deltas, 0.95),
            pixelCount: count)
    }

    /// CIELAB ΔE76 (Euclidean distance in Lab) between two Lab colours.
    public static func deltaE76(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    /// Converts an 8-bit sRGB triple to CIELAB (D65 white point).
    public static func srgb8ToLab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD3<Double> {
        let lin = SIMD3(srgbToLinear(Double(r) / 255),
                        srgbToLinear(Double(g) / 255),
                        srgbToLinear(Double(b) / 255))
        // Linear sRGB → CIE XYZ (D65).
        let x = 0.4124564 * lin.x + 0.3575761 * lin.y + 0.1804375 * lin.z
        let y = 0.2126729 * lin.x + 0.7151522 * lin.y + 0.0721750 * lin.z
        let z = 0.0193339 * lin.x + 0.1191920 * lin.y + 0.9503041 * lin.z
        // Normalise by the D65 reference white.
        let xr = x / 0.95047, yr = y, zr = z / 1.08883
        let fx = labF(xr), fy = labF(yr), fz = labF(zr)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// sRGB EOTF: gamma-encoded [0,1] → linear [0,1].
    public static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// The CIELAB `f` companding function.
    static func labF(_ t: Double) -> Double {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        return t > epsilon ? Foundation.cbrt(t) : (kappa * t + 16) / 116
    }

    /// Linear-interpolated percentile of `values` (0…1 fraction). Empty input
    /// scores 0.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = fraction * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

extension GoldenImage {

    /// Decodes a PNG (or any ImageIO-supported format) at `url` into a
    /// straight-RGBA8 ``GoldenImage``. Uses ImageIO/CoreGraphics — available on
    /// the macOS CI runner without a GPU — so the golden-image gate can decode
    /// committed reference PNGs in a plain unit test.
    public static func decode(contentsOf url: URL) throws -> GoldenImage {
        let data = try Data(contentsOf: url)
        return try decode(data: data)
    }

    /// Decodes image bytes into a straight-RGBA8 ``GoldenImage``.
    public static func decode(data: Data) throws -> GoldenImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DecodeError.notAnImage
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw DecodeError.empty }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = rgba.withUnsafeMutableBytes({ buffer in
            CGContext(data: buffer.baseAddress,
                      width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: colorSpace, bitmapInfo: bitmapInfo)
        }) else {
            throw DecodeError.contextCreationFailed
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GoldenImage(width: width, height: height, rgba: rgba)
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case notAnImage, empty, contextCreationFailed
    }
}
#endif
