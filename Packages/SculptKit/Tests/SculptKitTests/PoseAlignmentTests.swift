import Foundation
import Testing
@testable import SculptKit

/// Sculpt-accuracy P3 (#84): the coarse-to-fine pose estimator. Acceptance is
/// asserted on the P0 corpus: the estimator reports a pose residual for every
/// labelled reference, converges within the terminal step, is deterministic
/// (no run-to-run drift, the F4 defect), and the ablation decomposes similarity
/// shortfall into pose gain vs shape deficit against the legacy 16-grid.
@Suite struct PoseAlignmentTests {

    /// A unimodal synthetic score: 1 at the true pose, decaying linearly with
    /// angular distance — the exact-ground-truth analogue of "render the model
    /// at the candidate pose and measure silhouette agreement".
    static func coneScore(truth: ViewPose) -> @Sendable (ViewPose) async -> Double {
        { pose in 1 - pose.angularDistance(to: truth) / 180 }
    }

    // MARK: - Acceptance: residual per P0 reference

    @Test func estimateRecoversEveryP0CorpusPose() async {
        for spec in EvalCorpus.specs() {
            let result = await PoseAlignment.estimate(score: Self.coneScore(truth: spec.pose))
            let residual = result.pose.angularDistance(to: spec.pose)
            #expect(residual <= 3, "\(spec.name): residual \(residual)° > 3°")
        }
    }

    /// F4's core defect was drift: identical inputs produced different "best"
    /// angles. The estimator is a pure function of score and options.
    @Test func estimateIsDeterministic() async {
        let truth = ViewPose(azimuthDegrees: 305, elevationDegrees: 12)
        let a = await PoseAlignment.estimate(score: Self.coneScore(truth: truth))
        let b = await PoseAlignment.estimate(score: Self.coneScore(truth: truth))
        #expect(a == b)
    }

    /// A flat score surface exercises the no-improvement path: the first
    /// candidate in scan order wins and every planned evaluation still runs
    /// (coarse 8×3 = 24, refinement 5 rounds × 8 neighbours = 40).
    @Test func flatScoreKeepsFirstCandidateAndCountsEvaluations() async {
        let result = await PoseAlignment.estimate { _ in 0.5 }
        #expect(result.pose == ViewPose(azimuthDegrees: 0, elevationDegrees: 5))
        #expect(result.coarsePose == result.pose)
        #expect(result.evaluations == 64)
        #expect(result.score == 0.5)
    }

    /// The estimator must respect its elevation clamp and wrap azimuth across
    /// the 0/360 seam while refining (truth just left of the seam).
    @Test func refinementWrapsAzimuthAndClampsElevation() async {
        let truth = ViewPose(azimuthDegrees: 355, elevationDegrees: -15)
        let result = await PoseAlignment.estimate(score: Self.coneScore(truth: truth))
        #expect(result.pose.angularDistance(to: truth) <= 3)
        #expect(result.pose.elevationDegrees >= -15)

        // Elevation candidates beyond the clamp are pulled into range.
        let high = ViewPose(azimuthDegrees: 90, elevationDegrees: 75)
        let clamped = await PoseAlignment.estimate(
            options: .init(coarseElevations: [200]),
            score: Self.coneScore(truth: high))
        #expect(clamped.pose.elevationDegrees <= 75)
    }

    @Test func optionsClampDegenerateValues() async {
        let options = PoseAlignment.SearchOptions(
            coarseAzimuthStepDegrees: 0, coarseElevations: [], refinementRounds: -2)
        #expect(options.coarseAzimuthStepDegrees == 1)
        #expect(options.coarseElevations == [25])
        #expect(options.refinementRounds == 0)
        // Zero refinement rounds: the coarse winner is the final answer.
        let giant = PoseAlignment.SearchOptions(
            coarseAzimuthStepDegrees: 400, coarseElevations: [10], refinementRounds: 0)
        #expect(giant.coarseAzimuthStepDegrees == 360)
        let result = await PoseAlignment.estimate(options: giant) { _ in 1 }
        #expect(result.evaluations == 1)
        #expect(result.pose == result.coarsePose)
    }

    @Test func angleHelpers() {
        #expect(PoseAlignment.wrapAzimuth(-10) == 350)
        #expect(PoseAlignment.wrapAzimuth(370) == 10)
        #expect(PoseAlignment.wrapAzimuth(0) == 0)
        let options = PoseAlignment.SearchOptions()
        #expect(PoseAlignment.clampElevation(100, options) == 75)
        #expect(PoseAlignment.clampElevation(-100, options) == -15)
    }

    // MARK: - Legacy baseline + ablation

    @Test func legacyGrid16MatchesItsContract() async {
        // 8 azimuths × 2 elevations, winner = nearest grid entry to the truth.
        let truth = ViewPose(azimuthDegrees: 130, elevationDegrees: 25)
        let result = await PoseAlignment.legacyGrid16(score: Self.coneScore(truth: truth))
        #expect(result.evaluations == 16)
        #expect(result.pose == ViewPose(azimuthDegrees: 135, elevationDegrees: 30))
        // Flat surface: first grid entry kept (no-improvement path).
        let flat = await PoseAlignment.legacyGrid16 { _ in 0 }
        #expect(flat.pose == ViewPose(azimuthDegrees: 0, elevationDegrees: 10))
    }

    /// The measured F4 ablation on a P0 reference: alignment must recover at
    /// least what the brute-force grid found (pose gain ≥ 0), the shape deficit
    /// is what remains at the true pose, and the residual is reported.
    @Test func ablationDecomposesPoseVersusShape() async throws {
        let car = try #require(EvalCorpus.specs().first { $0.name == "car" })
        // Cap the score below 1 so a genuine "shape deficit" exists.
        let score: @Sendable (ViewPose) async -> Double = { pose in
            0.9 * (1 - pose.angularDistance(to: car.pose) / 180)
        }
        let ablation = await PoseAlignment.ablation(truePose: car.pose, score: score)
        #expect(ablation.alignedScore >= ablation.bruteForceScore)
        #expect(abs(ablation.poseGain - (ablation.alignedScore - ablation.bruteForceScore)) < 1e-12)
        #expect(abs(ablation.shapeDeficit - (1 - ablation.trueScore)) < 1e-12)
        #expect(ablation.poseResidualDegrees <= 3)
        #expect(abs(ablation.trueScore - 0.9) < 1e-12)
    }

    // MARK: - Through the real metric

    /// End-to-end with the actual shape metric instead of a synthetic cone: a
    /// pose offset translates the rendered silhouette, and the estimator finds
    /// the pose whose "render" best matches the reference through
    /// `ImageSimilarity` — analysis-by-synthesis exactly as the tool runs it.
    @Test func estimateAlignsThroughImageSimilarity() async throws {
        let car = try #require(EvalCorpus.specs().first { $0.name == "car" })
        let reference = EvalCorpus.render(car).matted

        @Sendable func rendered(at pose: ViewPose) -> RasterImage {
            // Pose error shifts the silhouette in the frame (a small-angle
            // stand-in for reprojection): 90° of azimuth ≈ half a frame.
            let dx = (pose.azimuthDegrees - car.pose.azimuthDegrees) / 180
            let dy = (pose.elevationDegrees - car.pose.elevationDegrees) / 180
            let shifted = SilhouetteSpec(name: "shifted", pose: pose) { nx, ny in
                car.isForeground(nx - dx, ny - dy)
            }
            return EvalCorpus.render(shifted).matted
        }

        let result = await PoseAlignment.estimate { pose in
            ImageSimilarity.compare(reference: reference, render: rendered(at: pose)).shapeScore
        }
        // Sub-frame alignment: the recovered pose leaves the silhouette within
        // a couple of grid cells of the reference.
        #expect(result.pose.angularDistance(to: car.pose) <= 6)
        #expect(result.score >= 0.9)
    }
}
