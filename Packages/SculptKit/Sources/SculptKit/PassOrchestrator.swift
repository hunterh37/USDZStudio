import Foundation

/// Why an `advance(after:)` was rejected. `continue` is the only gated
/// decision — it requires the full evidence bundle img2threejs demands: a
/// render, a comparison sheet, and a passing vision score.
public enum AdvanceError: Error, Equatable, CustomStringConvertible {
    case notContinuablePass(SculptPass)
    case continueRequiresRender
    case continueRequiresComparisonSheet
    case continueRequiresScore
    case scoreBelowThreshold(score: Double, threshold: Double)
    case continueRequiresMeasuredSimilarity
    case similarityBelowFloor(measured: Double, floor: Double)

    public var description: String {
        switch self {
        case .notContinuablePass(let p):
            return "cannot advance from \(p.rawValue): pipeline already halted or complete"
        case .continueRequiresRender:
            return "continue requires a render (renderPath)"
        case .continueRequiresComparisonSheet:
            return "continue requires a comparison sheet (comparisonSheetPath)"
        case .continueRequiresScore:
            return "continue requires a vision score"
        case .scoreBelowThreshold(let score, let threshold):
            return "vision score \(score) is below the acceptance threshold \(threshold)"
        case .continueRequiresMeasuredSimilarity:
            return "continue requires a measured similarity (this assessment sets a similarity floor)"
        case .similarityBelowFloor(let measured, let floor):
            return "measured similarity \(measured) is below the acceptance floor \(floor)"
        }
    }
}

/// The result of applying a `PassReview` to the orchestrator.
public enum AdvanceResult: Sendable, Equatable {
    /// Pass accepted; the named pass is now unlocked and current.
    case advanced(to: SculptPass)
    /// Pass accepted and it was the last one — the object is complete.
    case completed
    /// Staying on the current pass to refine spec or code.
    case staying(SculptPass)
    /// Paused, awaiting user input.
    case awaitingInput(SculptPass)
    /// Pipeline halted by decision.
    case halted(SculptPass)
}

/// The locked-pass state machine. Holds the current pass and enforces the
/// gate on `continue`; `refineSpec`/`refineCode` keep the same pass unlocked;
/// `requestInput`/`stop` pause or halt. Value type so callers can snapshot it.
public struct PassOrchestrator: Sendable, Equatable, Codable {
    public private(set) var current: SculptPass
    public private(set) var isComplete: Bool
    public private(set) var isHalted: Bool

    public init(startingAt pass: SculptPass = .blockout) {
        self.current = pass
        self.isComplete = false
        self.isHalted = false
    }

    /// True when neither complete nor halted — i.e. work can still happen.
    public var isActive: Bool { !isComplete && !isHalted }

    /// Apply a review's decision. `threshold` is the minimum passing score for
    /// `continue` (typically `assessment.policy.minScore`); `similarityFloor`
    /// (typically `assessment.policy.similarityFloor`) is the minimum *measured*
    /// reference-vs-render similarity. When the floor is > 0 a `continue` must
    /// carry a `measuredSimilarity` that meets it — the deterministic gate that
    /// the subjective score cannot bypass. A floor of 0 disables the check,
    /// preserving pre-floor behaviour.
    @discardableResult
    public mutating func advance(
        after review: PassReview, threshold: Double, similarityFloor: Double = 0
    ) throws -> AdvanceResult {
        guard isActive else {
            throw AdvanceError.notContinuablePass(current)
        }
        switch review.decision {
        case .continue:
            guard review.renderPath != nil else { throw AdvanceError.continueRequiresRender }
            guard review.comparisonSheetPath != nil else { throw AdvanceError.continueRequiresComparisonSheet }
            guard let score = review.score else { throw AdvanceError.continueRequiresScore }
            guard score >= threshold else {
                throw AdvanceError.scoreBelowThreshold(score: score, threshold: threshold)
            }
            if similarityFloor > 0 {
                guard let measured = review.measuredSimilarity else {
                    throw AdvanceError.continueRequiresMeasuredSimilarity
                }
                guard measured >= similarityFloor else {
                    throw AdvanceError.similarityBelowFloor(measured: measured, floor: similarityFloor)
                }
            }
            if let next = current.next {
                current = next
                return .advanced(to: next)
            } else {
                isComplete = true
                return .completed
            }
        case .refineSpec, .refineCode:
            return .staying(current)
        case .requestInput:
            return .awaitingInput(current)
        case .stop:
            isHalted = true
            return .halted(current)
        }
    }
}
