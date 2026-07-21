import Foundation

/// How faithfully the output must match the requested target color
/// (specs/recoloring.md §Calibrated accuracy mode).
public enum RecolorMode: String, Sendable, CaseIterable, Codable {
    /// Map the region's hue/chroma straight to the target. Fast, live-drag path.
    case direct
    /// Report the achieved ΔE against the target so callers can gate on it. In
    /// the pure engine (no lighting), albedo ≈ rendered color under a neutral
    /// illuminant, so the achieved swatch is the recolored region's mean color.
    case calibrated
}

/// A complete recolor request: the target color, how to interpret the source,
/// and the detail-preservation knobs. The batch/CLI/console entry point.
public struct RecolorRequest: Sendable {
    /// Target color as encoded components in [0,1], interpreted in `targetSpace`.
    public var target: (r: Double, g: Double, b: Double)
    /// Color space of `target` (a hex picker is sRGB; an eyedropper may be P3).
    public var targetSpace: TextureColorSpace
    /// Color space the *texture* samples live in.
    public var sourceSpace: TextureColorSpace
    public var mode: RecolorMode
    public var lightnessBias: Double
    public var chromaPreservation: Double
    public var preserveHueVariation: Bool
    /// Optional region mask; `nil` recolors the whole image.
    public var mask: RecolorMask?

    public init(
        target: (r: Double, g: Double, b: Double),
        targetSpace: TextureColorSpace = .sRGB,
        sourceSpace: TextureColorSpace = .sRGB,
        mode: RecolorMode = .direct,
        lightnessBias: Double = 0,
        chromaPreservation: Double = 1,
        preserveHueVariation: Bool = false,
        mask: RecolorMask? = nil
    ) {
        self.target = target
        self.targetSpace = targetSpace
        self.sourceSpace = sourceSpace
        self.mode = mode
        self.lightnessBias = lightnessBias
        self.chromaPreservation = chromaPreservation
        self.preserveHueVariation = preserveHueVariation
        self.mask = mask
    }
}

/// The recolored raster plus its accuracy readout.
public struct RecolorResult: Sendable {
    public var image: RGBAImage
    /// CIELab ΔE*76 between the target and the achieved region mean color. The
    /// golden gate asserts this is < 2.0 in calibrated mode on flat swatches.
    public var achievedDeltaE: Double
}

public enum RecolorPipeline {
    public enum PipelineError: Error, Equatable {
        case invalidTargetColor
        case maskSizeMismatch
    }

    /// Recolor a decoded raster.
    public static func recolor(_ image: RGBAImage, request: RecolorRequest) throws -> RecolorResult {
        let mask: RecolorMask
        if let provided = request.mask {
            guard provided.width == image.width, provided.height == image.height else {
                throw PipelineError.maskSizeMismatch
            }
            mask = provided
        } else {
            mask = .full(width: image.width, height: image.height)
        }

        let targetLinear = ColorManagement.decode(request.target, from: request.targetSpace)
        let targetLCh = OKLCh(oklab: OKLab(linear: targetLinear))
        let targetLab = CIELab(linear: targetLinear)

        let engine = RecolorEngine()
        var params = RecolorParameters(
            target: targetLCh,
            lightnessBias: request.lightnessBias,
            chromaPreservation: request.chromaPreservation,
            preserveHueVariation: request.preserveHueVariation
        )
        // Direct mode is a single pass; calibrated iterates (≤3 passes) to null
        // out the residual between the target and the achieved region mean,
        // which drifts under gamut clamping. The response is near-linear, so a
        // few additive corrections converge (specs/recoloring.md §Calibrated).
        let passes = request.mode == .calibrated ? 3 : 1
        var output = image
        var achievedDeltaE = 0.0
        for pass in 0..<passes {
            output = engine.recolor(image, colorSpace: request.sourceSpace, parameters: params, mask: mask)
            let stats = engine.statistics(of: output, colorSpace: request.sourceSpace, mask: mask)
            let achievedLinear = LinearRGB(oklab: OKLab(oklch: OKLCh(
                L: stats.meanLightness, C: stats.meanChroma, h: stats.meanHue
            )))
            achievedDeltaE = deltaE76(targetLab, CIELab(linear: achievedLinear))
            // Correct the next pass toward the target by the residual. Calibrated
            // mode matches the *whole* target color, so it also biases lightness
            // (direct mode deliberately preserves the source's lightness/detail).
            if pass + 1 < passes {
                params.targetHue += targetLCh.h - stats.meanHue
                params.targetChroma += targetLCh.C - stats.meanChroma
                params.lightnessBias += targetLCh.L - stats.meanLightness
            }
        }
        return RecolorResult(image: output, achievedDeltaE: achievedDeltaE)
    }

    /// Decode PNG/any-image bytes, recolor, and re-encode as lossless PNG.
    public static func recolorImageData(_ data: Data, request: RecolorRequest) throws -> (data: Data, achievedDeltaE: Double) {
        let image = try RGBAImageCodec.decode(data)
        let result = try recolor(image, request: request)
        return (try RGBAImageCodec.encodePNG(result.image), result.achievedDeltaE)
    }

    /// Parse a `#RRGGBB` string into a request target (sRGB). Convenience for
    /// CLI/console callers that take a hex string.
    public static func target(fromHex hex: String) throws -> (r: Double, g: Double, b: Double) {
        guard let parsed = ColorManagement.parseHexSRGB(hex) else {
            throw PipelineError.invalidTargetColor
        }
        return parsed
    }
}
