import Foundation
import Testing
@testable import SculptKit

/// #173: the comparison-sheet similarity was inverted and unpassable.
///
/// Three separate inversions were reported from a real balisong build:
///   1. `silhouetteIoU == 0.0` on renders whose silhouette visibly overlapped
///      the reference — the masks were compared in raw image space, so any
///      translation yielded an empty intersection;
///   2. adding *correct* materials **lowered** the score (0.484 → 0.386),
///      because appearance was measured over the full frame including
///      background, penalising correctly dark anodised parts against a bright
///      reference backdrop;
///   3. the pose a human judged the best match scored the **worst**.
///
/// The consequence was a gate that could not be cleared honestly, and which
/// pushed an agent optimising against it to make the model worse.
@Suite("Similarity alignment (#173)")
struct SimilarityAlignmentTests {

    // MARK: - Builders

    static func image(_ w: Int, _ h: Int,
                      _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> RasterImage {
        var bytes = [UInt8](); bytes.reserveCapacity(w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b, a) = pixel(x, y)
                bytes += [r, g, b, a]
            }
        }
        return RasterImage(width: w, height: h, rgba: bytes)!
    }

    /// An opaque `side` square whose top-left corner sits at (`x`, `y`), on a
    /// transparent field — lets a subject be *moved* without changing shape.
    static func square(_ dim: Int, side: Int, x: Int, y: Int,
                       color: (UInt8, UInt8, UInt8) = (200, 200, 200)) -> RasterImage {
        image(dim, dim) { px, py in
            (px >= x && px < x + side && py >= y && py < y + side)
                ? (color.0, color.1, color.2, 255) : (0, 0, 0, 0)
        }
    }

    static func centeredSquare(_ dim: Int, side: Int,
                               color: (UInt8, UInt8, UInt8) = (200, 200, 200)) -> RasterImage {
        square(dim, side: side, x: (dim - side) / 2, y: (dim - side) / 2, color: color)
    }

    /// An opaque subject on an opaque *background* colour — the configuration
    /// where full-frame appearance scoring went wrong.
    static func subjectOnBackground(
        _ dim: Int, side: Int, subject: (UInt8, UInt8, UInt8), background: (UInt8, UInt8, UInt8)
    ) -> RasterImage {
        let lo = (dim - side) / 2, hi = lo + side
        return image(dim, dim) { x, y in
            (x >= lo && x < hi && y >= lo && y < hi)
                ? (subject.0, subject.1, subject.2, 255)
                : (background.0, background.1, background.2, 255)
        }
    }

    // MARK: - Inversion 1: translated silhouettes must not score zero

    /// The headline defect. An identical shape shifted within the frame is a
    /// *framing* difference, not a fidelity difference — it must score near 1,
    /// and it must not score 0.
    @Test func translatedIdenticalShapeScoresNearOne() {
        let reference = Self.square(64, side: 24, x: 8, y: 8)
        let shifted = Self.square(64, side: 24, x: 32, y: 32)
        let report = ImageSimilarity.compare(reference: reference, render: shifted)
        #expect(report.silhouetteIoU > 0.9)
        #expect(report.aggregate > 0.9)
        #expect(report.measurementFailed == false)
    }

    /// The regression assertion the issue asked for by name: IoU > 0 for a
    /// render offset from an otherwise identical reference.
    @Test func offsetRenderHasNonZeroIoU() {
        let reference = Self.square(64, side: 20, x: 4, y: 4)
        let offset = Self.square(64, side: 20, x: 40, y: 40)
        // Disjoint in raw image space — this is precisely the 0.0 that was
        // being reported as a score.
        #expect(ImageSimilarity.compare(reference: reference, render: offset).rawSilhouetteIoU == 0)
        // But aligned, the shapes agree.
        #expect(ImageSimilarity.compare(reference: reference, render: offset).silhouetteIoU > 0)
    }

    /// Translation invariance must not be bought by throwing away *scale*: a
    /// model built at the wrong size is a genuine fidelity error, and a gate
    /// blind to it would be useless.
    @Test func scaleErrorIsStillPenalised() {
        let reference = Self.centeredSquare(64, side: 40)
        let halfSize = Self.centeredSquare(64, side: 20)
        let report = ImageSimilarity.compare(reference: reference, render: halfSize)
        #expect(report.silhouetteIoU < 0.5)
        #expect(report.aggregate < 0.8)
    }

    // MARK: - Inversion 2: background must not dominate appearance

    /// Correct materials lowered the score because appearance was measured over
    /// the whole frame: the reference sat on a bright backdrop and the render on
    /// a dark one, so a correctly dark subject was punished for the *backdrop*.
    ///
    /// Appearance is now measured inside the union of the two silhouettes, so a
    /// matching subject on a mismatched background scores well.
    @Test func mismatchedBackgroundDoesNotSinkAMatchingSubject() {
        let subject: (UInt8, UInt8, UInt8) = (30, 90, 40)      // dark anodised green
        let reference = Self.subjectOnBackground(64, side: 28, subject: subject,
                                                 background: (20, 24, 80))   // navy
        let render = Self.subjectOnBackground(64, side: 28, subject: subject,
                                              background: (5, 5, 5))         // near-black
        let report = ImageSimilarity.compare(reference: reference, render: render)
        #expect(report.appearanceScore > 0.8)
        #expect(report.aggregate > 0.8)
    }

    /// The other half of that claim: a genuinely *wrong* subject colour must
    /// still be penalised. Restricting to the mask must not make appearance
    /// blind, only unbiased.
    @Test func wrongSubjectColourIsStillPenalised() {
        let reference = Self.centeredSquare(64, side: 28, color: (20, 200, 20))   // bright green
        let wrong = Self.centeredSquare(64, side: 28, color: (200, 20, 20))       // red
        let matching = Self.centeredSquare(64, side: 28, color: (20, 200, 20))
        let wrongReport = ImageSimilarity.compare(reference: reference, render: wrong)
        let matchReport = ImageSimilarity.compare(reference: reference, render: matching)
        #expect(matchReport.appearanceScore > wrongReport.appearanceScore)
    }

    /// The inversion stated most directly: applying correct materials must never
    /// score *below* the untextured grey clay it replaced.
    @Test func correctMaterialsDoNotScoreBelowGreyClay() {
        let reference = Self.subjectOnBackground(
            64, side: 28, subject: (40, 160, 60), background: (20, 24, 80))
        let textured = Self.subjectOnBackground(
            64, side: 28, subject: (40, 160, 60), background: (5, 5, 5))
        let greyClay = Self.subjectOnBackground(
            64, side: 28, subject: (140, 140, 140), background: (5, 5, 5))
        let texturedScore = ImageSimilarity.compare(reference: reference, render: textured).aggregate
        let clayScore = ImageSimilarity.compare(reference: reference, render: greyClay).aggregate
        #expect(texturedScore > clayScore)
    }

    // MARK: - Measurement failure is not a score

    /// When both silhouettes are non-empty yet the aligned masks still don't
    /// intersect, that is a measurement error. Reporting it as a fidelity of
    /// zero is what told the balisong build its best pose was its worst.
    @Test func nonIntersectingAlignedMasksAreReportedAsMeasurementFailure() {
        // A thin horizontal bar against a thin vertical bar: both non-empty,
        // both centered, and their aligned masks barely relate.
        let horizontal = Self.image(64, 64) { x, y in
            (y >= 31 && y <= 32 && x >= 2 && x <= 61) ? (200, 200, 200, 255) : (0, 0, 0, 0)
        }
        let vertical = Self.image(64, 64) { x, y in
            (x >= 31 && x <= 32 && y >= 2 && y <= 61) ? (200, 200, 200, 255) : (0, 0, 0, 0)
        }
        let report = ImageSimilarity.compare(reference: horizontal, render: vertical)
        // These do overlap at the centre, so this is a *valid* low score —
        // the flag must stay off.
        #expect(report.measurementFailed == false)
        #expect(report.silhouetteIoU > 0)
    }

    /// The true positive: a reference whose mass sits at two far edges has its
    /// centroid in empty space, so aligning centroids can leave two non-empty
    /// masks genuinely disjoint. That is the alignment failing, not the model
    /// scoring zero — and the gate must be told so rather than handed a 0.0 to
    /// optimise against.
    @Test func disjointAlignedMasksSetTheMeasurementFailureFlag() {
        // Two dots at opposite edges: centroid lands in the empty middle.
        let barbell = Self.image(64, 64) { x, y in
            let left = x >= 2 && x <= 9 && y >= 28 && y <= 35
            let right = x >= 54 && x <= 61 && y >= 28 && y <= 35
            return (left || right) ? (200, 200, 200, 255) : (0, 0, 0, 0)
        }
        // A single centred dot: its own centroid is its middle.
        let dot = Self.square(64, side: 8, x: 28, y: 28)
        let report = ImageSimilarity.compare(reference: barbell, render: dot)
        #expect(report.measurementFailed)
        #expect(report.silhouetteIoU == 0)
    }

    /// An empty render against a real reference is a true zero, not a
    /// measurement failure: there is genuinely nothing there.
    @Test func emptyRenderIsATrueZeroNotAMeasurementFailure() {
        let reference = Self.centeredSquare(64, side: 32)
        let empty = Self.image(64, 64) { _, _ in (0, 0, 0, 0) }
        let report = ImageSimilarity.compare(reference: reference, render: empty)
        #expect(report.silhouetteIoU == 0)
        #expect(report.measurementFailed == false)
    }

    @Test func bothEmptyStillTriviallyAgree() {
        let empty = Self.image(32, 32) { _, _ in (0, 0, 0, 0) }
        let report = ImageSimilarity.compare(reference: empty, render: empty)
        #expect(report.silhouetteIoU == 1)
        #expect(report.measurementFailed == false)
    }

    // MARK: - Components are reported separately

    /// The issue asked for the components to be reported separately so a shape
    /// win isn't silently cancelled by a background artefact.
    @Test func rawAndAlignedIoUAreBothReported() {
        let reference = Self.square(64, side: 20, x: 4, y: 4)
        let offset = Self.square(64, side: 20, x: 40, y: 40)
        let report = ImageSimilarity.compare(reference: reference, render: offset)
        #expect(report.rawSilhouetteIoU == 0)          // framing
        #expect(report.silhouetteIoU > 0)              // fidelity
        #expect(report.silhouetteIoU > report.rawSilhouetteIoU)
    }

    @Test func reportRoundTripsWithTheNewFields() throws {
        let report = SimilarityReport(
            silhouetteIoU: 0.8, luminanceCorrelation: 0.7, ssim: 0.6, shapeScore: 0.82,
            appearanceScore: 0.65, aggregate: 0.75, rawSilhouetteIoU: 0.1,
            measurementFailed: true)
        let decoded = try JSONDecoder().decode(
            SimilarityReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }

    /// Reports written before these fields existed must still decode.
    @Test func legacyReportDecodesWithDefaultedFields() throws {
        let json = """
        {"silhouetteIoU":0.5,"luminanceCorrelation":0.5,"ssim":0.5,
         "shapeScore":0.5,"appearanceScore":0.5,"aggregate":0.5}
        """
        let decoded = try JSONDecoder().decode(SimilarityReport.self, from: Data(json.utf8))
        #expect(decoded.rawSilhouetteIoU == 0)
        #expect(decoded.measurementFailed == false)
    }

    // MARK: - Masked metric internals

    @Test func maskedCellsFallBackToTheFullGridWhenEmpty() {
        #expect(ImageSimilarity.cells(count: 4, mask: [false, false, false, false]) == [0, 1, 2, 3])
        #expect(ImageSimilarity.cells(count: 4, mask: nil) == [0, 1, 2, 3])
        // A mask of the wrong length can't be trusted; use everything.
        #expect(ImageSimilarity.cells(count: 4, mask: [true]) == [0, 1, 2, 3])
        #expect(ImageSimilarity.cells(count: 4, mask: [true, false, true, false]) == [0, 2])
    }

    /// A grid with no foreground has no centroid, so the crop must fall back to
    /// the full frame rather than dividing by zero.
    @Test func emptyGridCropsToTheFullFrame() {
        let empty = Self.image(16, 16) { _, _ in (0, 0, 0, 0) }
        let grid = ImageSimilarity.Grid(image: empty, side: ImageSimilarity.gridSide)
        let rect = grid.subjectCenteredRect(in: empty)
        #expect(rect == ImageSimilarity.Grid.Rect(x: 0, y: 0, width: 16, height: 16))
    }

    /// The crop rect is offset, so it can extend past the image edge; sampling
    /// must clamp rather than trap.
    @Test func offCentreSubjectDoesNotSampleOutOfBounds() {
        // Subject flush against the top-left corner: the centered crop starts
        // at a negative origin.
        let corner = Self.square(32, side: 8, x: 0, y: 0)
        let report = ImageSimilarity.compare(reference: corner, render: corner)
        #expect(report.silhouetteIoU == 1)
        #expect(report.aggregate > 0.99)
    }

    // MARK: - Worst-view aggregation still holds

    /// A good angle must not hide a bad one.
    @Test func worstViewPicksTheLowestAggregate() throws {
        let reference = Self.centeredSquare(64, side: 32)
        let good = Self.centeredSquare(64, side: 32)
        let bad = Self.centeredSquare(64, side: 8)
        let worst = try #require(ImageSimilarity.worstView([
            (reference: reference, render: good),
            (reference: reference, render: bad),
        ]))
        #expect(worst.aggregate
                == ImageSimilarity.compare(reference: reference, render: bad).aggregate)
    }
}
