import Foundation

// Sculpt-accuracy P0 (#81): a ground-truth evaluation harness.
//
// The accuracy program is measurement-gated: every later change must move a
// *number* on a fixed benchmark, not a screenshot. The blocker was that we had
// no labelled ground truth. This harness supplies it the honest way — a
// procedurally-rendered synthetic corpus. Because we author each silhouette
// ourselves, the foreground mask and the camera pose are known *exactly* by
// construction, so mask-IoU and pose residual are measured against real ground
// truth rather than fabricated labels.
//
// The harness only *reads* the existing `ImageSimilarity` metric; it does not
// change any gate or threshold (program guardrail).

/// A camera view of a reference, in the same azimuth/elevation convention the
/// comparison turntable uses. Ground truth for the pose-residual measurement.
public struct ViewPose: Sendable, Equatable, Codable {
    public var azimuthDegrees: Double
    public var elevationDegrees: Double

    public init(azimuthDegrees: Double, elevationDegrees: Double) {
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
    }

    /// Great-circle-ish angular distance between two poses, in degrees. Azimuth
    /// wraps at 360°; the two axes are combined in quadrature so a pure-azimuth
    /// and a pure-elevation error of equal size weigh equally.
    public func angularDistance(to other: ViewPose) -> Double {
        let rawAz = abs(azimuthDegrees - other.azimuthDegrees).truncatingRemainder(dividingBy: 360)
        let az = min(rawAz, 360 - rawAz)
        let el = abs(elevationDegrees - other.elevationDegrees)
        return (az * az + el * el).squareRoot()
    }
}

/// The per-reference decomposition the harness emits. `shapeTerm` and
/// `appearanceTerm` are deliberately separated: shape is meaningful from the
/// blockout pass on, appearance only once a `material` is applied (aligns with
/// PRs #76/#78 and sets up P2/P3).
public struct EvalRecord: Sendable, Equatable, Codable {
    public var name: String
    /// Silhouette agreement (shape) — high from the first grey pass.
    public var shapeTerm: Double
    /// Colour/tonal agreement (appearance) — only trustworthy from `material`.
    public var appearanceTerm: Double
    /// IoU of the *produced* foreground mask against the ground-truth mask.
    /// Measures segmentation quality, the F1 lever.
    public var maskIoU: Double
    /// Angular distance between the reference pose and the render pose.
    public var poseResidualDegrees: Double

    public init(name: String, shapeTerm: Double, appearanceTerm: Double,
                maskIoU: Double, poseResidualDegrees: Double) {
        self.name = name
        self.shapeTerm = shapeTerm
        self.appearanceTerm = appearanceTerm
        self.maskIoU = maskIoU
        self.poseResidualDegrees = poseResidualDegrees
    }
}

/// One labelled benchmark entry: a shape rendered two ways (a clean matte with a
/// real alpha channel, and a "raw photo" over a textured opaque background) plus
/// the exact ground-truth foreground and the exact camera pose.
public struct LabelledReference: Sendable {
    public var name: String
    public var pose: ViewPose
    /// Ground-truth foreground at `ImageSimilarity.gridSide` resolution.
    public var trueForeground: [Bool]
    /// Clean matte: foreground opaque, background fully transparent.
    public var matted: RasterImage
    /// Raw photo: foreground over an opaque textured background (no alpha).
    public var raw: RasterImage
}

public enum SculptEvalHarness {

    /// Evaluate a render against a reference, decomposing into the four measured
    /// quantities. `trueForeground` is the ground-truth mask (length
    /// `side*side`); when omitted, mask-IoU is reported against the reference's
    /// own derived foreground (i.e. 1.0 by definition) and only shape/appearance
    /// carry signal.
    public static func evaluate(
        name: String,
        reference: RasterImage,
        render: RasterImage,
        trueForeground: [Bool]? = nil,
        referencePose: ViewPose,
        renderPose: ViewPose,
        side: Int = ImageSimilarity.gridSide
    ) -> EvalRecord {
        let refGrid = ImageSimilarity.Grid(image: reference, side: side)
        let renGrid = ImageSimilarity.Grid(image: render, side: side)

        let shape = ImageSimilarity.silhouetteIoU(refGrid, renGrid)
        let ssimValue = ImageSimilarity.ssim(refGrid, renGrid)
        let luma = ImageSimilarity.luminanceCorrelation(refGrid, renGrid)
        // Appearance = colour/tonal blend, renormalised so the two channels that
        // survive the shape/appearance split still sum to 1.
        let appearance = ImageSimilarity.clamp01(
            (ImageSimilarity.weightSSIM * ssimValue + ImageSimilarity.weightLuma * luma)
            / (ImageSimilarity.weightSSIM + ImageSimilarity.weightLuma))

        let truth = trueForeground ?? refGrid.foreground
        let maskIoU = maskAgreement(produced: refGrid.foreground, truth: truth)

        return EvalRecord(
            name: name,
            shapeTerm: shape,
            appearanceTerm: appearance,
            maskIoU: maskIoU,
            poseResidualDegrees: referencePose.angularDistance(to: renderPose))
    }

    /// IoU between a produced foreground mask and the ground-truth mask. When
    /// the two lengths disagree the comparison is meaningless → 0. Two empty
    /// masks trivially agree → 1.
    static func maskAgreement(produced: [Bool], truth: [Bool]) -> Double {
        guard produced.count == truth.count else { return 0 }
        var intersection = 0, union = 0
        for i in 0..<produced.count {
            if produced[i] || truth[i] { union += 1 }
            if produced[i] && truth[i] { intersection += 1 }
        }
        guard union > 0 else { return 1 }
        return Double(intersection) / Double(union)
    }

    /// Spearman's rank correlation coefficient between two equal-length series.
    /// Reported by the correlation study (metric vs a ground-truth ranking).
    /// Returns 0 for fewer than two points or a series with no rank variance.
    public static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count >= 2 else { return 0 }
        let ra = ranks(a), rb = ranks(b)
        let n = Double(ra.count)
        let meanA = ra.reduce(0, +) / n
        let meanB = rb.reduce(0, +) / n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in 0..<ra.count {
            let da = ra[i] - meanA, db = rb[i] - meanB
            cov += da * db; varA += da * da; varB += db * db
        }
        guard varA > 1e-12, varB > 1e-12 else { return 0 }
        return cov / (varA.squareRoot() * varB.squareRoot())
    }

    /// Fractional ranks (ties share the average rank) — the standard Spearman
    /// tie correction.
    static func ranks(_ values: [Double]) -> [Double] {
        let sorted = values.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].element == sorted[i].element { j += 1 }
            let rank = Double(i + j) / 2 + 1  // average of the tied 1-based ranks
            for k in i...j { result[sorted[k].offset] = rank }
            i = j + 1
        }
        return result
    }
}
