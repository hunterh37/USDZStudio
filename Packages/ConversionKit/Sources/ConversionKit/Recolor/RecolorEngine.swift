import Foundation

/// Perceptual statistics of the masked region, in OKLCh (specs/recoloring.md
/// §RecolorEngine step 2). The remap is expressed relative to these means so
/// per-pixel *deviation* — the grain, weave, and shading — survives the edit.
public struct RegionStatistics: Hashable, Sendable {
    public var meanLightness: Double
    public var meanChroma: Double
    /// Circular mean hue in radians, [0, 2π).
    public var meanHue: Double
    /// Total mask weight (Σ coverage), not a raw pixel count.
    public var weight: Double

    public init(meanLightness: Double, meanChroma: Double, meanHue: Double, weight: Double) {
        self.meanLightness = meanLightness
        self.meanChroma = meanChroma
        self.meanHue = meanHue
        self.weight = weight
    }
}

/// How the recolor remaps the masked region toward a target color while
/// preserving texture detail (specs/recoloring.md §RecolorEngine).
public struct RecolorParameters: Sendable {
    /// Target hue in radians (the region is rotated to this hue).
    public var targetHue: Double
    /// Target mean chroma; per-pixel chroma deviation is preserved on top.
    public var targetChroma: Double
    /// Added to every pixel's lightness for light↔dark recolors. A
    /// detail-preservation floor keeps mid-tone variation from clipping flat.
    public var lightnessBias: Double
    /// 0 = flatten chroma to the target; 1 = keep full per-pixel chroma spread.
    public var chromaPreservation: Double
    /// Keep each pixel's hue offset from the region mean (multi-tone prints)
    /// rather than snapping every pixel to exactly `targetHue`.
    public var preserveHueVariation: Bool

    public init(
        targetHue: Double,
        targetChroma: Double,
        lightnessBias: Double = 0,
        chromaPreservation: Double = 1,
        preserveHueVariation: Bool = false
    ) {
        self.targetHue = targetHue
        self.targetChroma = targetChroma
        self.lightnessBias = lightnessBias
        self.chromaPreservation = chromaPreservation
        self.preserveHueVariation = preserveHueVariation
    }

    /// Build parameters that recolor a region toward a single target color.
    public init(
        target: OKLCh,
        lightnessBias: Double = 0,
        chromaPreservation: Double = 1,
        preserveHueVariation: Bool = false
    ) {
        self.init(
            targetHue: target.h,
            targetChroma: target.C,
            lightnessBias: lightnessBias,
            chromaPreservation: chromaPreservation,
            preserveHueVariation: preserveHueVariation
        )
    }
}

/// The CPU reference recolor engine (specs/recoloring.md, Tier B). This is the
/// authority the Metal live path is parity-tested against: same input → ΔE <
/// 0.5 per pixel. Pure, deterministic, no GPU or I/O.
public struct RecolorEngine: Sendable {
    public init() {}

    /// Region statistics over the masked pixels of `image` in `colorSpace`.
    /// Pixels with zero coverage contribute nothing; hue is a coverage-weighted
    /// circular mean.
    public func statistics(
        of image: RGBAImage,
        colorSpace: TextureColorSpace,
        mask: RecolorMask
    ) -> RegionStatistics {
        precondition(mask.width == image.width && mask.height == image.height, "mask/image size mismatch")
        var sumL = 0.0
        var sumC = 0.0
        var sumSin = 0.0
        var sumCos = 0.0
        var totalWeight = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let w = mask.weight(x: x, y: y)
                if w <= 0 { continue }
                let lch = OKLCh(oklab: OKLab(linear: linear(of: image.pixel(x: x, y: y), colorSpace: colorSpace)))
                sumL += w * lch.L
                sumC += w * lch.C
                sumSin += w * Foundation.sin(lch.h)
                sumCos += w * Foundation.cos(lch.h)
                totalWeight += w
            }
        }
        if totalWeight == 0 {
            return RegionStatistics(meanLightness: 0, meanChroma: 0, meanHue: 0, weight: 0)
        }
        var meanHue = atan2(sumSin, sumCos)
        if meanHue < 0 { meanHue += 2 * .pi }
        return RegionStatistics(
            meanLightness: sumL / totalWeight,
            meanChroma: sumC / totalWeight,
            meanHue: meanHue,
            weight: totalWeight
        )
    }

    /// Recolor `image` (interpreting samples as `colorSpace`) toward the target
    /// described by `parameters`, blended by `mask`. Alpha is preserved; the
    /// output raster is the same size and color space as the input.
    public func recolor(
        _ image: RGBAImage,
        colorSpace: TextureColorSpace,
        parameters: RecolorParameters,
        mask: RecolorMask
    ) -> RGBAImage {
        let stats = statistics(of: image, colorSpace: colorSpace, mask: mask)
        var output = image
        for y in 0..<image.height {
            for x in 0..<image.width {
                let w = mask.weight(x: x, y: y)
                let original = image.pixel(x: x, y: y)
                if w <= 0 { continue }
                let srcLCh = OKLCh(oklab: OKLab(linear: linear(of: original, colorSpace: colorSpace)))
                let remapped = remap(srcLCh, stats: stats, parameters: parameters)
                // Blend original→remapped by mask weight for feathered edges.
                let blended = blend(from: srcLCh, to: remapped, t: w)
                let encoded = ColorManagement.encode(LinearRGB(oklab: OKLab(oklch: blended)), to: colorSpace)
                output.setPixel(x: x, y: y, to: (
                    r: byte(encoded.r), g: byte(encoded.g), b: byte(encoded.b), a: original.a
                ))
            }
        }
        return output
    }

    /// Mean CIELab ΔE*76 between two same-size images over `colorSpace`. The
    /// metric behind the accuracy readout and the CPU/GPU parity + golden gates.
    public func meanDeltaE76(_ lhs: RGBAImage, _ rhs: RGBAImage, colorSpace: TextureColorSpace) -> Double {
        precondition(lhs.width == rhs.width && lhs.height == rhs.height, "image size mismatch")
        var sum = 0.0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                let a = CIELab(linear: linear(of: lhs.pixel(x: x, y: y), colorSpace: colorSpace))
                let b = CIELab(linear: linear(of: rhs.pixel(x: x, y: y), colorSpace: colorSpace))
                sum += deltaE76(a, b)
            }
        }
        return sum / Double(lhs.pixelCount)
    }

    // MARK: - Remap

    private func remap(_ src: OKLCh, stats: RegionStatistics, parameters: RecolorParameters) -> OKLCh {
        // Hue: snap to target, optionally carrying each pixel's offset from the
        // region mean so multi-tone prints keep their internal hue structure.
        var hue = parameters.targetHue
        if parameters.preserveHueVariation {
            hue += src.h - stats.meanHue
        }
        hue = normalizeHue(hue)
        // Chroma: target mean + preserved per-pixel deviation (never negative).
        let deviation = (src.C - stats.meanChroma) * parameters.chromaPreservation
        let chroma = max(0, parameters.targetChroma + deviation)
        // Lightness: keep each pixel's value (this is what preserves grain and
        // shading) and apply only the optional bias for light↔dark recolors.
        let lightness = src.L + parameters.lightnessBias
        return OKLCh(L: clampLightness(lightness), C: chroma, h: hue)
    }

    private func blend(from a: OKLCh, to b: OKLCh, t: Double) -> OKLCh {
        if t >= 1 { return b }
        // Blend in Lab to avoid hue-wrap artifacts at partial coverage.
        let la = OKLab(oklch: a)
        let lb = OKLab(oklch: b)
        let mixed = OKLab(L: lerp(la.L, lb.L, t), a: lerp(la.a, lb.a, t), b: lerp(la.b, lb.b, t))
        return OKLCh(oklab: mixed)
    }

    // MARK: - Helpers

    private func linear(of pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), colorSpace: TextureColorSpace) -> LinearRGB {
        ColorManagement.decode(
            (Double(pixel.r) / 255.0, Double(pixel.g) / 255.0, Double(pixel.b) / 255.0),
            from: colorSpace
        )
    }

    private func byte(_ v: Double) -> UInt8 {
        UInt8((ColorManagement.clamp01(v) * 255.0).rounded())
    }

    private func normalizeHue(_ h: Double) -> Double {
        var hue = h.truncatingRemainder(dividingBy: 2 * .pi)
        if hue < 0 { hue += 2 * .pi }
        return hue
    }

    private func clampLightness(_ L: Double) -> Double {
        L < 0 ? 0 : (L > 1 ? 1 : L)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
