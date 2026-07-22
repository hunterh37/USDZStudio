import Testing
import Foundation
@testable import SculptKit

// Sculpt-accuracy integration (#93): the frozen-fixture regression gate.
//
// `SculptEvalHarness.benchmark()` runs the whole P0 labelled corpus through the
// *same* metric the live continue-gate uses. This suite freezes every measured
// quantity per reference and fails on ANY drift in either direction — a drop is
// a regression; an unexplained rise means the fixtures below must be re-frozen
// in the same commit that moves the metric, so a metric change can never land
// silently (the ratchet discipline used by roundtrip-gate.sh / coverage-gate.sh).
//
// The CI job runs this suite via `scripts/sculpt-eval-gate.sh`.
@Suite("Sculpt-accuracy regression — frozen P0 benchmark")
struct EvalRegressionTests {

    /// Frozen expectations: name → (shapeTerm, appearanceTerm, maskIoU, poseResidualDegrees).
    /// Captured from `SculptEvalHarness.benchmark()` at #93 integration. Every
    /// number is exact ground truth by construction (see EvalCorpus). Re-freeze
    /// intentionally, in the metric-changing commit, never as drive-by noise.
    static let frozen: [String: (shape: Double, appearance: Double, mask: Double, pose: Double)] = [
        "disc":      (0.612999, 0.024317, 1.0, 0.0),
        "box":       (0.508259, 0.027420, 1.0, 0.0),
        "tall":      (0.403361, 0.030625, 1.0, 0.0),
        "wide":      (0.352941, 0.032964, 1.0, 0.0),
        "triangle":  (0.341135, 0.036766, 1.0, 0.0),
        "car":       (0.255608, 0.040693, 1.0, 0.0),
        "ell":       (0.382091, 0.030490, 1.0, 0.0),
        "ring":      (0.464102, 0.025956, 1.0, 0.0),
        "cross":     (0.408685, 0.030534, 1.0, 0.0),
        "ellipse":   (0.344186, 0.034378, 1.0, 0.0),
        "diamond":   (0.391645, 0.032017, 1.0, 0.0),
        "trapezoid": (0.367213, 0.032406, 1.0, 0.0),
    ]

    /// Tolerance: the harness is fully deterministic, so this only absorbs
    /// floating-point noise, not genuine metric drift.
    static let tolerance = 1e-4

    @Test func benchmarkMatchesFrozenFixtures() {
        let records = SculptEvalHarness.benchmark()
        // Every frozen reference is present exactly once (no shape dropped/added).
        #expect(records.count == Self.frozen.count)
        var seen = Set<String>()
        for record in records {
            seen.insert(record.name)
            guard let want = Self.frozen[record.name] else {
                Issue.record("unexpected corpus entry '\(record.name)' — re-freeze fixtures")
                continue
            }
            #expect(abs(record.shapeTerm - want.shape) < Self.tolerance,
                    "\(record.name).shapeTerm drifted: \(record.shapeTerm) vs frozen \(want.shape)")
            #expect(abs(record.appearanceTerm - want.appearance) < Self.tolerance,
                    "\(record.name).appearanceTerm drifted: \(record.appearanceTerm) vs frozen \(want.appearance)")
            #expect(abs(record.maskIoU - want.mask) < Self.tolerance,
                    "\(record.name).maskIoU drifted: \(record.maskIoU) vs frozen \(want.mask)")
            #expect(abs(record.poseResidualDegrees - want.pose) < Self.tolerance,
                    "\(record.name).poseResidual drifted: \(record.poseResidualDegrees) vs frozen \(want.pose)")
        }
        #expect(seen == Set(Self.frozen.keys), "corpus membership changed — re-freeze fixtures")
    }

    // MARK: - gate integration (#93): the split feeds `aggregate`, floor held.

    /// The live gate metric now blends shape and appearance; a faithful render
    /// (reference compared with itself) must still score a perfect 1.0 so no
    /// currently-passing render is pushed below `policy.similarityFloor`.
    @Test func faithfulRenderClearsFloorUnderSplitMetric() {
        for ref in EvalCorpus.benchmark() {
            let report = ImageSimilarity.compare(reference: ref.matted, render: ref.matted)
            #expect(abs(report.shapeScore - 1.0) < 1e-9)
            #expect(abs(report.appearanceScore - 1.0) < 1e-9)
            #expect(abs(report.aggregate - 1.0) < 1e-9)
            // Comfortably above the highest floor in use (character 0.55).
            #expect(report.aggregate >= 0.55)
        }
    }

    /// The aggregate is exactly the documented shape-dominant blend of the split.
    @Test func aggregateIsTheShapeAppearanceBlend() {
        let ref = EvalCorpus.benchmark()[0]
        let report = ImageSimilarity.compare(reference: ref.matted, render: ref.raw)
        let expected = ImageSimilarity.clamp01(
            ImageSimilarity.weightShape * report.shapeScore
            + ImageSimilarity.weightAppearance * report.appearanceScore)
        #expect(abs(report.aggregate - expected) < 1e-12)
    }
}
