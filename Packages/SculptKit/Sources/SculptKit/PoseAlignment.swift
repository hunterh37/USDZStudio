import Foundation

// Sculpt-accuracy P3 (#84): camera-pose alignment before comparison.
//
// Finding F4 (`specs/sculpt-accuracy-analysis.md`): the comparison angle was
// chosen by rendering a flat 16-entry azimuth/elevation grid and keeping the
// best IoU. There was no estimate of the reference camera pose, so pose
// mismatch was confounded with shape error and the "best" angle drifted
// run-to-run (125°/305°/325°) — the search, not the geometry, moved the number.
//
// This module estimates the reference pose by **analysis-by-synthesis**: a
// deterministic coarse-to-fine search over the orbit sphere that maximises a
// caller-supplied score (typically the concavity-preserving shape score of the
// model rendered at the candidate pose against the matted reference — the
// issue's "coarse pose regressor" alternative, kept honest by the residual
// refinement the spec asks to retain). SculptKit stays renderer-free: the
// caller supplies `score(pose)` (AgentMCP renders through its injected
// renderer seam; tests use synthetic pose-parameterised silhouettes with exact
// ground truth).
//
// Determinism is the point: given the same score function the search always
// returns the same pose, and its terminal step size bounds the pose residual —
// unlike the legacy grid, whose winner drifted with whatever 16 angles it
// happened to sample. `legacyGrid16` reproduces that baseline so the ablation
// (pose gain vs shape deficit) is measured, not asserted.
public enum PoseAlignment {

    /// Search configuration. Defaults trade ~60 score evaluations for a
    /// terminal step under 1.5°, comfortably inside the acceptance residual.
    public struct SearchOptions: Sendable, Equatable {
        /// Coarse azimuth step in degrees (must divide 360 into ≥ 1 samples).
        public var coarseAzimuthStepDegrees: Double
        /// Coarse elevation candidates in degrees.
        public var coarseElevations: [Double]
        /// Refinement rounds; each halves the step and probes the 8 neighbours.
        public var refinementRounds: Int
        /// Elevation is clamped to this range throughout the search.
        public var elevationRange: ClosedRange<Double>

        public init(coarseAzimuthStepDegrees: Double = 45,
                    coarseElevations: [Double] = [5, 25, 45],
                    refinementRounds: Int = 5,
                    elevationRange: ClosedRange<Double> = -15...75) {
            self.coarseAzimuthStepDegrees = min(360, max(1, coarseAzimuthStepDegrees))
            self.coarseElevations = coarseElevations.isEmpty ? [25] : coarseElevations
            self.refinementRounds = max(0, refinementRounds)
            self.elevationRange = elevationRange
        }
    }

    /// The estimated pose plus the evidence trail: the score it achieved, the
    /// coarse-stage winner it refined from, and how many evaluations were spent.
    public struct SearchResult: Sendable, Equatable {
        public var pose: ViewPose
        public var score: Double
        public var coarsePose: ViewPose
        public var evaluations: Int
    }

    /// The measured F4 ablation: how much of the similarity shortfall is pose
    /// (recovered by alignment) versus shape (remains even at the true pose).
    public struct Ablation: Sendable, Equatable {
        /// Best score of the legacy 16-entry brute-force grid (the baseline).
        public var bruteForceScore: Double
        /// Score at the coarse-to-fine estimated pose.
        public var alignedScore: Double
        /// Score at the ground-truth pose (shape error in isolation).
        public var trueScore: Double
        /// Score gain attributable to pose alignment (aligned − brute force).
        public var poseGain: Double
        /// Similarity still missing at the true pose — genuine shape error.
        public var shapeDeficit: Double
        /// Angular distance from the estimated pose to the ground truth.
        public var poseResidualDegrees: Double
    }

    // MARK: - Coarse-to-fine estimation

    /// Estimate the pose maximising `score`: a coarse orbit sweep, then
    /// `refinementRounds` of halved-step 8-neighbour hill climbing around the
    /// incumbent. Ties keep the earlier candidate in scan order, so the result
    /// is a pure function of the score function and options.
    public static func estimate(
        options: SearchOptions = SearchOptions(),
        score: (ViewPose) async throws -> Double
    ) async rethrows -> SearchResult {
        var evaluations = 0
        var best = ViewPose(azimuthDegrees: 0, elevationDegrees: clampElevation(options.coarseElevations[0], options))
        var bestScore = -Double.infinity

        // Coarse sweep.
        var azimuth = 0.0
        while azimuth < 360 {
            for elevation in options.coarseElevations {
                let candidate = ViewPose(
                    azimuthDegrees: azimuth,
                    elevationDegrees: clampElevation(elevation, options))
                let s = try await score(candidate)
                evaluations += 1
                if s > bestScore {
                    bestScore = s
                    best = candidate
                }
            }
            azimuth += options.coarseAzimuthStepDegrees
        }
        let coarse = best

        // Refinement: halve the step, probe the 8 neighbours, keep the best.
        var step = options.coarseAzimuthStepDegrees / 2
        for _ in 0..<options.refinementRounds {
            for dAz in [-step, 0, step] {
                for dEl in [-step, 0, step] where !(dAz == 0 && dEl == 0) {
                    let candidate = ViewPose(
                        azimuthDegrees: wrapAzimuth(best.azimuthDegrees + dAz),
                        elevationDegrees: clampElevation(best.elevationDegrees + dEl, options))
                    let s = try await score(candidate)
                    evaluations += 1
                    if s > bestScore {
                        bestScore = s
                        best = candidate
                    }
                }
            }
            step /= 2
        }

        return SearchResult(pose: best, score: bestScore, coarsePose: coarse, evaluations: evaluations)
    }

    /// The legacy F4 baseline: the flat 16-entry grid (8 azimuths × 2
    /// elevations) whose winner used to *be* the comparison angle. Kept only as
    /// the measured baseline the ablation compares against.
    public static func legacyGrid16(
        score: (ViewPose) async throws -> Double
    ) async rethrows -> SearchResult {
        var best = ViewPose(azimuthDegrees: 0, elevationDegrees: 10)
        var bestScore = -Double.infinity
        var evaluations = 0
        for azStep in 0..<8 {
            for elevation in [10.0, 30.0] {
                let candidate = ViewPose(azimuthDegrees: Double(azStep) * 45, elevationDegrees: elevation)
                let s = try await score(candidate)
                evaluations += 1
                if s > bestScore {
                    bestScore = s
                    best = candidate
                }
            }
        }
        return SearchResult(pose: best, score: bestScore, coarsePose: best, evaluations: evaluations)
    }

    /// Run the full F4 ablation for one reference with a known pose: brute
    /// force vs aligned vs ground truth, decomposed into pose gain and shape
    /// deficit, with the estimation residual reported.
    public static func ablation(
        truePose: ViewPose,
        options: SearchOptions = SearchOptions(),
        score: (ViewPose) async throws -> Double
    ) async rethrows -> Ablation {
        let brute = try await legacyGrid16(score: score)
        let aligned = try await estimate(options: options, score: score)
        let trueScore = try await score(truePose)
        return Ablation(
            bruteForceScore: brute.score,
            alignedScore: aligned.score,
            trueScore: trueScore,
            poseGain: aligned.score - brute.score,
            shapeDeficit: 1 - trueScore,
            poseResidualDegrees: aligned.pose.angularDistance(to: truePose))
    }

    // MARK: - Angle helpers

    /// Wrap an azimuth into [0, 360).
    static func wrapAzimuth(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    static func clampElevation(_ degrees: Double, _ options: SearchOptions) -> Double {
        min(options.elevationRange.upperBound, max(options.elevationRange.lowerBound, degrees))
    }
}
