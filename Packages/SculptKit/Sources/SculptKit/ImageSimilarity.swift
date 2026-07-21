import Foundation

/// A decoded raster image: RGBA8, row-major, `width * height * 4` bytes. Pure
/// value type so SculptKit computes similarity without importing any imaging
/// framework — the AgentMCP layer decodes PNGs (via ImageIO) and hands the
/// pixels here. This keeps the fidelity metric fully deterministic and testable.
public struct RasterImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// RGBA8 bytes, length exactly `width * height * 4`.
    public let rgba: [UInt8]

    /// Fails when the dimensions are non-positive or the buffer length does not
    /// match `width * height * 4`.
    public init?(width: Int, height: Int, rgba: [UInt8]) {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// The measured fidelity of a render against its reference — the deterministic
/// floor that sits *under* the agent's subjective vision score. Every component
/// is in 0...1; `aggregate` is the single number the continue-gate compares to
/// the policy's `similarityFloor`.
///
/// Sculpt-accuracy integration (#93): the gate now consumes an explicit
/// **shape / appearance split**. `shapeScore` is the concavity-preserving
/// `ShapeMetric` term (silhouette IoU blended with symmetric contour agreement,
/// so a blob filling a gapped reference cannot outscore a faithful, holed
/// shape — the F2 fix); `appearanceScore` is the colour/tonal term, only
/// trustworthy once a material is applied (F3). `aggregate` is a shape-dominant
/// blend of the two (see `ImageSimilarity.weightShape`/`weightAppearance`),
/// replacing the previous flat IoU/SSIM/luma blend. The three legacy
/// components remain reported for diagnostics and back-compatible JSON.
public struct SimilarityReport: Sendable, Equatable, Codable {
    /// Intersection-over-union of the two silhouettes (shape agreement).
    public var silhouetteIoU: Double
    /// Pearson correlation of the luminance fields, remapped to 0...1 (tonal agreement).
    public var luminanceCorrelation: Double
    /// Global structural similarity (SSIM) on luminance.
    public var ssim: Double
    /// Concavity-preserving shape term (`ShapeMetric`): IoU blended with contour
    /// agreement. Meaningful from the blockout pass on.
    public var shapeScore: Double
    /// Colour/tonal agreement term. Only trustworthy from the `material` pass.
    public var appearanceScore: Double
    /// Shape-dominant blend of `shapeScore` and `appearanceScore`, clamped to
    /// 0...1 — the single number the continue-gate compares to the floor.
    public var aggregate: Double

    public init(silhouetteIoU: Double, luminanceCorrelation: Double, ssim: Double,
                shapeScore: Double, appearanceScore: Double, aggregate: Double) {
        self.silhouetteIoU = silhouetteIoU
        self.luminanceCorrelation = luminanceCorrelation
        self.ssim = ssim
        self.shapeScore = shapeScore
        self.appearanceScore = appearanceScore
        self.aggregate = aggregate
    }
}

/// Deterministic reference-vs-render similarity. All three metrics are computed
/// on a fixed-size resampled luminance/alpha grid so images of differing
/// resolutions compare cleanly and the result is stable across machines.
public enum ImageSimilarity {
    /// Side of the square grid both images are resampled to before comparison.
    public static let gridSide = 64
    /// Alpha above this (0...255) counts a pixel as foreground when the image
    /// carries a real alpha channel.
    static let alphaForegroundCutoff: UInt8 = 127
    /// Per-channel delta from the background sample above which an opaque pixel
    /// counts as foreground (used when there is no usable alpha channel).
    static let opaqueForegroundDelta = 0.12

    /// Relative weights of SSIM and luminance *within* the appearance term
    /// (renormalised to sum to 1 by the appearance blend). SSIM dominates
    /// because structural agreement is a stronger tonal cue than mean-luma
    /// correlation. `ShapeMetric` reuses these to keep one appearance formula.
    static let weightSSIM = 0.35
    static let weightLuma = 0.15

    /// Shape / appearance split for the gate `aggregate` (#93). Shape is
    /// dominant: it is the F2-hardened, concavity-preserving signal and is
    /// meaningful from the first grey pass, whereas appearance only pays off
    /// once a material lands. Re-tuned against the P0 harness corpus — the
    /// `policy.similarityFloor` is held, only the blend changed.
    static let weightShape = 0.6
    static let weightAppearance = 0.4

    /// Compare a reference image to a render, returning the fidelity report.
    /// The reported `shapeScore`/`appearanceScore` are the split the gate
    /// consumes; `aggregate` is their shape-dominant blend.
    public static func compare(reference: RasterImage, render: RasterImage) -> SimilarityReport {
        let side = gridSide
        let ref = Grid(image: reference, side: side)
        let ren = Grid(image: render, side: side)

        // Legacy per-metric diagnostics (unchanged formulas, still reported).
        let iou = silhouetteIoU(ref, ren)
        let luma = luminanceCorrelation(ref, ren)
        let ssimValue = ssim(ref, ren)

        // Shape / appearance split. Both reuse the already-resampled grids so
        // there is no redundant sampling. `appearance` is the same renormalised
        // SSIM/luma blend `ShapeMetric.appearanceScore` computes.
        let shape = ShapeMetric.shapeScore(reference: ref.foreground, render: ren.foreground, side: side).score
        let appearance = clamp01(
            (weightSSIM * ssimValue + weightLuma * luma) / (weightSSIM + weightLuma))
        let aggregate = clamp01(weightShape * shape + weightAppearance * appearance)

        return SimilarityReport(
            silhouetteIoU: iou, luminanceCorrelation: luma, ssim: ssimValue,
            shapeScore: shape, appearanceScore: appearance, aggregate: aggregate)
    }

    /// The worst (minimum-aggregate) report across a set of reference/render
    /// pairs — one per rendered view. A single bad angle can't hide behind a
    /// good one. Returns nil for an empty set.
    public static func worstView(_ pairs: [(reference: RasterImage, render: RasterImage)]) -> SimilarityReport? {
        var worst: SimilarityReport?
        for pair in pairs {
            let report = compare(reference: pair.reference, render: pair.render)
            if worst == nil || report.aggregate < worst!.aggregate {
                worst = report
            }
        }
        return worst
    }

    // MARK: - Metrics

    /// Intersection-over-union of the two foreground masks. When neither image
    /// has any foreground (both empty), the shapes trivially agree → 1.
    static func silhouetteIoU(_ a: Grid, _ b: Grid) -> Double {
        var intersection = 0
        var union = 0
        for i in 0..<a.foreground.count {
            let inA = a.foreground[i]
            let inB = b.foreground[i]
            if inA || inB { union += 1 }
            if inA && inB { intersection += 1 }
        }
        guard union > 0 else { return 1 }
        return Double(intersection) / Double(union)
    }

    /// Pearson correlation of the luminance fields, remapped from [-1, 1] to
    /// [0, 1]. When either field is flat (zero variance) correlation is
    /// undefined, so we fall back to 1 minus their mean-luminance gap.
    static func luminanceCorrelation(_ a: Grid, _ b: Grid) -> Double {
        let n = Double(a.luma.count)
        let meanA = a.luma.reduce(0, +) / n
        let meanB = b.luma.reduce(0, +) / n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in 0..<a.luma.count {
            let da = a.luma[i] - meanA
            let db = b.luma[i] - meanB
            cov += da * db
            varA += da * da
            varB += db * db
        }
        guard varA > 1e-12, varB > 1e-12 else {
            return clamp01(1 - abs(meanA - meanB))
        }
        let r = cov / (varA.squareRoot() * varB.squareRoot())
        return clamp01((r + 1) / 2)
    }

    /// Global SSIM on the luminance fields (single window over the whole grid).
    static func ssim(_ a: Grid, _ b: Grid) -> Double {
        let n = Double(a.luma.count)
        let muA = a.luma.reduce(0, +) / n
        let muB = b.luma.reduce(0, +) / n
        var varA = 0.0, varB = 0.0, cov = 0.0
        for i in 0..<a.luma.count {
            let da = a.luma[i] - muA
            let db = b.luma[i] - muB
            varA += da * da
            varB += db * db
            cov += da * db
        }
        varA /= n; varB /= n; cov /= n
        let c1 = 0.0001    // (0.01 * L)^2 with L = 1
        let c2 = 0.0009    // (0.03 * L)^2 with L = 1
        let numerator = (2 * muA * muB + c1) * (2 * cov + c2)
        let denominator = (muA * muA + muB * muB + c1) * (varA + varB + c2)
        return clamp01(numerator / denominator)
    }

    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    // MARK: - Resampled grid

    /// A `side × side` resample of an image into a normalized luminance field
    /// (0...1) plus a foreground mask. Nearest-neighbour sampling keeps it
    /// deterministic and dependency-free.
    struct Grid {
        let side: Int
        var luma: [Double]
        var foreground: [Bool]

        init(image: RasterImage, side: Int) {
            self.side = side
            var luma = [Double](repeating: 0, count: side * side)
            var alpha = [Double](repeating: 0, count: side * side)
            var rgb = [(Double, Double, Double)](repeating: (0, 0, 0), count: side * side)
            let usesAlpha = Grid.hasMeaningfulAlpha(image)

            for gy in 0..<side {
                let sy = min(image.height - 1, gy * image.height / side)
                for gx in 0..<side {
                    let sx = min(image.width - 1, gx * image.width / side)
                    let base = (sy * image.width + sx) * 4
                    let r = Double(image.rgba[base]) / 255
                    let g = Double(image.rgba[base + 1]) / 255
                    let b = Double(image.rgba[base + 2]) / 255
                    let a = Double(image.rgba[base + 3]) / 255
                    let idx = gy * side + gx
                    luma[idx] = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    alpha[idx] = a
                    rgb[idx] = (r, g, b)
                }
            }

            self.luma = luma
            if usesAlpha {
                let cutoff = Double(ImageSimilarity.alphaForegroundCutoff) / 255
                self.foreground = alpha.map { $0 > cutoff }
            } else {
                // No usable alpha: treat pixels close to the corner-sampled
                // background colour as background, the rest as foreground.
                let bg = rgb[0]
                let delta = ImageSimilarity.opaqueForegroundDelta
                self.foreground = rgb.map { px in
                    abs(px.0 - bg.0) > delta || abs(px.1 - bg.1) > delta || abs(px.2 - bg.2) > delta
                }
            }
        }

        /// An image has a meaningful alpha channel when at least one pixel is
        /// non-opaque; a fully-opaque buffer carries no silhouette information
        /// in its alpha, so we fall back to colour keying.
        static func hasMeaningfulAlpha(_ image: RasterImage) -> Bool {
            var i = 3
            while i < image.rgba.count {
                if image.rgba[i] < 255 { return true }
                i += 4
            }
            return false
        }
    }
}
