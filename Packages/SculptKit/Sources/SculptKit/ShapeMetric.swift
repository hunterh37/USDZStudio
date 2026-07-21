import Foundation

// Sculpt-accuracy P2 (#83): a concavity-preserving, shape-vs-appearance metric.
//
// Measured defect (F2): against an *over-filled* reference silhouette, an
// origin-collapsed blockout blob scored 0.619 while the correctly-placed
// structural car scored 0.483 — the blob beat the real car. Cause: a filled
// reference has no interior concavities (wheel gaps, under-body, cabin cut-ins),
// so a dense convex blob maximises silhouette IoU while a faithful, gapped car
// is penalised. The signal was anti-correlated with fidelity.
//
// The fix has two halves:
//   1. Preserve interior gaps in the reference (don't over-fill) — enforced by
//      the caller / matting stage; this metric simply *uses* the concavities.
//   2. A shape score that blends silhouette IoU with a symmetric contour
//      (chamfer) agreement, so a shape whose boundary — including the boundary
//      of its interior holes — matches the reference is rewarded over one that
//      merely fills the same bounding area.
//
// Appearance (colour/tone) is reported separately and is only meaningful from
// the `material` pass, keeping a shape check from being dragged down by grey
// clay (F3). Resolution is configurable so the F6 sensitivity can be reported.
// This is opt-in API; the existing `ImageSimilarity.compare` gate is untouched.

/// A shape-only fidelity report: silhouette overlap plus contour agreement.
public struct ShapeReport: Sendable, Equatable, Codable {
    /// Intersection-over-union of the foreground masks (area overlap).
    public var iou: Double
    /// Symmetric contour agreement in 0...1 (1 = boundaries coincide), derived
    /// from a normalized symmetric chamfer distance between the silhouette
    /// outlines — including the outlines of interior holes.
    public var contourAgreement: Double
    /// Blended shape score, clamped to 0...1.
    public var score: Double

    public init(iou: Double, contourAgreement: Double, score: Double) {
        self.iou = iou
        self.contourAgreement = contourAgreement
        self.score = score
    }
}

public enum ShapeMetric {
    /// IoU / contour blend weights. Contour is weighted heavily enough that a
    /// blob filling the same area as a gapped reference cannot outscore a shape
    /// that reproduces the concavities.
    static let weightIoU = 0.6
    static let weightContour = 0.4

    /// Compare the *shape* of a render to a reference at `side × side`. Higher
    /// resolution preserves finer contour detail (raise for a sensitivity
    /// study; the gate path keeps `ImageSimilarity.gridSide`).
    public static func shapeScore(reference: RasterImage, render: RasterImage,
                                  side: Int = ImageSimilarity.gridSide) -> ShapeReport {
        let refGrid = ImageSimilarity.Grid(image: reference, side: side)
        let renGrid = ImageSimilarity.Grid(image: render, side: side)
        return shapeScore(reference: refGrid.foreground, render: renGrid.foreground, side: side)
    }

    /// Shape score from raw foreground masks (both length `side*side`).
    static func shapeScore(reference: [Bool], render: [Bool], side: Int) -> ShapeReport {
        let iou = maskIoU(reference, render)
        let refEdges = boundary(reference, side: side)
        let renEdges = boundary(render, side: side)
        let agreement = contourAgreement(refEdges, renEdges, side: side)
        let score = ImageSimilarity.clamp01(weightIoU * iou + weightContour * agreement)
        return ShapeReport(iou: iou, contourAgreement: agreement, score: score)
    }

    /// Appearance (colour/tone) term, separated from shape. Only trustworthy
    /// once a material is applied — grey clay against a colour photo is a
    /// meaningless appearance comparison (F3).
    public static func appearanceScore(reference: RasterImage, render: RasterImage,
                                       side: Int = ImageSimilarity.gridSide) -> Double {
        let refGrid = ImageSimilarity.Grid(image: reference, side: side)
        let renGrid = ImageSimilarity.Grid(image: render, side: side)
        let ssimValue = ImageSimilarity.ssim(refGrid, renGrid)
        let luma = ImageSimilarity.luminanceCorrelation(refGrid, renGrid)
        return ImageSimilarity.clamp01(
            (ImageSimilarity.weightSSIM * ssimValue + ImageSimilarity.weightLuma * luma)
            / (ImageSimilarity.weightSSIM + ImageSimilarity.weightLuma))
    }

    // MARK: - internals

    static func maskIoU(_ a: [Bool], _ b: [Bool]) -> Double {
        guard a.count == b.count else { return 0 }
        var inter = 0, union = 0
        for i in 0..<a.count {
            if a[i] || b[i] { union += 1 }
            if a[i] && b[i] { inter += 1 }
        }
        guard union > 0 else { return 1 }
        return Double(inter) / Double(union)
    }

    /// Boundary cells: a foreground cell that touches background (or the image
    /// edge) on any 4-neighbour. Crucially, a cell bordering an *interior* hole
    /// is a boundary too, so preserved concavities contribute their outline.
    static func boundary(_ mask: [Bool], side: Int) -> [(Int, Int)] {
        var edges: [(Int, Int)] = []
        func fg(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < side && y >= 0 && y < side && mask[y * side + x]
        }
        for y in 0..<side {
            for x in 0..<side where mask[y * side + x] {
                if !fg(x - 1, y) || !fg(x + 1, y) || !fg(x, y - 1) || !fg(x, y + 1) {
                    edges.append((x, y))
                }
            }
        }
        return edges
    }

    /// Symmetric contour agreement in 0...1 from a normalized symmetric chamfer
    /// distance. Two empty contours agree (1); one empty and one not is total
    /// disagreement (0).
    static func contourAgreement(_ a: [(Int, Int)], _ b: [(Int, Int)], side: Int) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let meanAB = meanNearest(a, b)
        let meanBA = meanNearest(b, a)
        let symmetric = (meanAB + meanBA) / 2
        // Normalise by the grid side: a boundary displaced by a full frame is
        // maximal disagreement.
        return ImageSimilarity.clamp01(1 - symmetric / Double(side))
    }

    /// Mean over `from` of the Euclidean distance to the nearest cell in `to`.
    static func meanNearest(_ from: [(Int, Int)], _ to: [(Int, Int)]) -> Double {
        var total = 0.0
        for p in from {
            var best = Double.greatestFiniteMagnitude
            for q in to {
                let dx = Double(p.0 - q.0), dy = Double(p.1 - q.1)
                let d = dx * dx + dy * dy
                if d < best { best = d }
            }
            total += best.squareRoot()
        }
        return total / Double(from.count)
    }
}
