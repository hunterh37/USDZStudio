import Foundation

/// Technical fitness of a reference image for reconstruction — img2threejs's
/// `probe_image` intake step. SculptKit decodes no pixels; the agent supplies
/// the dimensions (and optional format/alpha facts it already has), and this
/// vets them deterministically before the pre-spec assessment runs.
public enum ProbeVerdict: String, Codable, Sendable, Equatable {
    /// Resolution and shape are comfortable for reconstruction.
    case usable
    /// Reconstructable, but detail budget or framing is constrained.
    case marginal
    /// Below the floor for a meaningful reconstruction — halt.
    case unusable
}

/// The report `sculpt_probe` returns. Pure data derived from dimensions.
public struct ProbeReport: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var verdict: ProbeVerdict
    /// Total pixels ÷ 1,000,000.
    public var megapixels: Double
    /// width ÷ height.
    public var aspectRatio: Double
    /// A conservative ceiling on distinct components single-image detail can
    /// support at this resolution — feeds the strict-quality component budget.
    public var recommendedMaxComponents: Int
    public var reasons: [String]

    public init(width: Int, height: Int, verdict: ProbeVerdict,
                megapixels: Double, aspectRatio: Double,
                recommendedMaxComponents: Int, reasons: [String]) {
        self.width = width
        self.height = height
        self.verdict = verdict
        self.megapixels = megapixels
        self.aspectRatio = aspectRatio
        self.recommendedMaxComponents = recommendedMaxComponents
        self.reasons = reasons
    }
}

public enum ImageProbe {
    /// Minimum side (px) below which a reference is unusable — matches the
    /// suitability gate's floor.
    static let minSide = 64
    /// Side (px) below which a reference is only marginal.
    static let comfortableSide = 256
    /// Aspect ratio beyond which framing is flagged (very tall/wide crops).
    static let extremeAspect = 3.0

    /// Vet a reference image's technical fitness from its pixel dimensions and,
    /// optionally, whether it carries an alpha channel (a clean cutout eases
    /// silhouette work).
    ///
    /// - Parameters:
    ///   - width/height: reference dimensions in pixels (must be positive).
    ///   - hasAlpha: whether the source has a transparency channel, if known.
    public static func probe(width: Int, height: Int, hasAlpha: Bool? = nil) -> ProbeReport {
        precondition(width > 0 && height > 0, "probe requires positive dimensions")
        let minSideActual = min(width, height)
        let megapixels = Double(width) * Double(height) / 1_000_000
        let aspect = Double(width) / Double(height)
        // Long-side/short-side ratio, orientation-independent.
        let aspectSkew = max(aspect, 1 / aspect)

        var reasons: [String] = []
        var verdict: ProbeVerdict = .usable

        if minSideActual < minSide {
            reasons.append("reference is \(width)×\(height)px — below the \(minSide)px floor")
            verdict = .unusable
        } else if minSideActual < comfortableSide {
            reasons.append("short side \(minSideActual)px is tight — detail beyond a few parts will be guessed")
            verdict = .marginal
        }

        if aspectSkew > extremeAspect {
            reasons.append("aspect \(rounded(aspect)) is extreme — the subject may be cropped or foreshortened")
            if verdict == .usable { verdict = .marginal }
        }

        if hasAlpha == true {
            reasons.append("alpha channel present — silhouette isolation is reliable")
        } else if hasAlpha == false {
            reasons.append("no alpha channel — the silhouette must be inferred from the background")
        }

        // Component ceiling scales with resolution: ~one part per comfortable
        // tile of pixels, clamped to a sane authoring range.
        let ceiling = verdict == .unusable
            ? 0
            : max(2, min(64, Int(megapixels * 24) + 2))

        return ProbeReport(
            width: width, height: height, verdict: verdict,
            megapixels: rounded(megapixels), aspectRatio: rounded(aspect),
            recommendedMaxComponents: ceiling, reasons: reasons)
    }

    /// Round to 3 decimals for stable, diffable report output.
    static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
