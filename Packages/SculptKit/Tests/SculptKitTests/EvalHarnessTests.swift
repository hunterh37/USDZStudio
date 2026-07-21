import Testing
import Foundation
@testable import SculptKit

@Suite("Sculpt-accuracy P0 — eval harness + synthetic corpus")
struct EvalHarnessTests {

    // MARK: - ViewPose

    @Test func matchedPoseHasZeroResidual() {
        let p = ViewPose(azimuthDegrees: 200, elevationDegrees: 8)
        #expect(p.angularDistance(to: p) == 0)
    }

    @Test func azimuthWrapsTheShortWay() {
        let a = ViewPose(azimuthDegrees: 350, elevationDegrees: 0)
        let b = ViewPose(azimuthDegrees: 10, elevationDegrees: 0)
        // 350→10 is 20° the short way, not 340°.
        #expect(abs(a.angularDistance(to: b) - 20) < 1e-9)
    }

    @Test func azimuthAndElevationCombineInQuadrature() {
        let a = ViewPose(azimuthDegrees: 0, elevationDegrees: 0)
        let b = ViewPose(azimuthDegrees: 30, elevationDegrees: 40)
        #expect(abs(a.angularDistance(to: b) - 50) < 1e-9)  // 3-4-5
    }

    // MARK: - mask agreement

    @Test func maskAgreementBasics() {
        #expect(SculptEvalHarness.maskAgreement(produced: [true, false], truth: [true, true]) == 0.5)
        #expect(SculptEvalHarness.maskAgreement(produced: [false, false], truth: [false, false]) == 1)
        // Length mismatch is meaningless.
        #expect(SculptEvalHarness.maskAgreement(produced: [true], truth: [true, false]) == 0)
    }

    // MARK: - Spearman

    @Test func spearmanPerfectAndInverse() {
        #expect(abs(SculptEvalHarness.spearman([1, 2, 3, 4], [10, 20, 30, 40]) - 1) < 1e-9)
        #expect(abs(SculptEvalHarness.spearman([1, 2, 3, 4], [40, 30, 20, 10]) + 1) < 1e-9)
    }

    @Test func spearmanHandlesTiesAndDegenerate() {
        // Ties share the average rank; correlation still well-defined.
        let rho = SculptEvalHarness.spearman([1, 1, 2, 3], [5, 5, 6, 7])
        #expect(rho > 0.9)
        // Too few points, or a flat series, has no rank correlation → 0.
        #expect(SculptEvalHarness.spearman([1], [1]) == 0)
        #expect(SculptEvalHarness.spearman([2, 2, 2], [1, 2, 3]) == 0)
    }

    @Test func ranksAverageTies() {
        // Two tied smallest values share rank (1+2)/2 = 1.5.
        #expect(SculptEvalHarness.ranks([5, 5, 9]) == [1.5, 1.5, 3])
    }

    // MARK: - evaluate

    @Test func selfComparisonIsPerfectShape() {
        let ref = EvalCorpus.render(EvalCorpus.specs().first { $0.name == "car" }!)
        let record = SculptEvalHarness.evaluate(
            name: "car", reference: ref.matted, render: ref.matted,
            trueForeground: ref.trueForeground,
            referencePose: ref.pose, renderPose: ref.pose)
        #expect(abs(record.shapeTerm - 1) < 1e-9)
        #expect(abs(record.maskIoU - 1) < 1e-9)      // clean matte recovers the truth exactly
        #expect(record.poseResidualDegrees == 0)
        #expect(record.appearanceTerm > 0.9)
    }

    @Test func evaluateWithoutTruthUsesDerivedForeground() {
        let ref = EvalCorpus.render(EvalCorpus.specs().first { $0.name == "disc" }!)
        let record = SculptEvalHarness.evaluate(
            name: "disc", reference: ref.matted, render: ref.matted,
            referencePose: ref.pose,
            renderPose: ViewPose(azimuthDegrees: 40, elevationDegrees: 0))
        #expect(abs(record.maskIoU - 1) < 1e-9)      // derived-vs-derived is 1 by definition
        #expect(abs(record.poseResidualDegrees - 40) < 1e-9)
    }

    // MARK: - corpus

    @Test func benchmarkHasAtLeastTenLabelledEntries() {
        let bench = EvalCorpus.benchmark()
        #expect(bench.count >= 10)
        for ref in bench {
            #expect(ref.trueForeground.contains(true))          // non-empty shape
            #expect(ref.trueForeground.contains(false))         // has background too
            #expect(ref.matted.width == ImageSimilarity.gridSide)
        }
    }

    /// F1 reproduction, as a measured number: a clean matte recovers the mask
    /// far better than a colour key on the raw photo.
    @Test func mattingBeatsRawSegmentation() {
        var mattedSum = 0.0, rawSum = 0.0
        let bench = EvalCorpus.benchmark()
        for ref in bench {
            let matted = SculptEvalHarness.evaluate(
                name: ref.name, reference: ref.matted, render: ref.matted,
                trueForeground: ref.trueForeground, referencePose: ref.pose, renderPose: ref.pose)
            let raw = SculptEvalHarness.evaluate(
                name: ref.name, reference: ref.raw, render: ref.raw,
                trueForeground: ref.trueForeground, referencePose: ref.pose, renderPose: ref.pose)
            mattedSum += matted.maskIoU
            rawSum += raw.maskIoU
        }
        let mattedMean = mattedSum / Double(bench.count)
        let rawMean = rawSum / Double(bench.count)
        // Matting is a large, reproducible win over raw colour keying (F1).
        #expect(mattedMean > rawMean + 0.2)
        // Frozen baseline: clean matte recovers ground truth exactly.
        #expect(abs(mattedMean - 1.0) < 0.01)
    }

    /// The P0 correlation study: metric-vs-ground-truth ranking. We shrink a
    /// known error monotonically and confirm the shape term tracks it — the
    /// honest stand-in for a human-ranking Spearman ρ, using exact ground truth.
    @Test func shapeTermCorrelatesWithGroundTruthRank() {
        let ref = EvalCorpus.render(EvalCorpus.specs().first { $0.name == "box" }!)
        let side = ImageSimilarity.gridSide

        // Renders with a monotonically shrinking horizontal shift error.
        var shifts = [Int]()
        var shapeScores = [Double]()
        for shift in stride(from: 20, through: 0, by: -4) {
            let shifted = shiftForeground(ref.trueForeground, by: shift, side: side)
            let render = maskToImage(shifted, side: side)
            let record = SculptEvalHarness.evaluate(
                name: "box", reference: ref.matted, render: render,
                trueForeground: ref.trueForeground, referencePose: ref.pose, renderPose: ref.pose)
            shifts.append(shift)
            shapeScores.append(record.shapeTerm)
        }
        // Less error (smaller shift) ⇒ higher shape score: strong negative rank
        // correlation between shift and score. Report the number.
        let rho = SculptEvalHarness.spearman(shifts.map(Double.init), shapeScores)
        #expect(rho <= -0.95)   // n = \(shifts.count)
    }

    // MARK: - helpers

    private func shiftForeground(_ mask: [Bool], by shift: Int, side: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<side {
            for x in 0..<side {
                let sx = x - shift
                if sx >= 0 && sx < side && mask[y * side + sx] { out[y * side + x] = true }
            }
        }
        return out
    }

    private func maskToImage(_ mask: [Bool], side: Int) -> RasterImage {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<mask.count where mask[i] {
            rgba[i * 4] = 60; rgba[i * 4 + 1] = 150; rgba[i * 4 + 2] = 60; rgba[i * 4 + 3] = 255
        }
        return RasterImage(width: side, height: side, rgba: rgba)!
    }
}
