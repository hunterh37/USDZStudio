import Foundation

/// The agent's decision after an authoring step (mirrors the sculpt review-loop contract).
public enum RigDecision: String, Sendable, Equatable, CaseIterable, Codable {
    case `continue`, refinePose, resolve, requestInput, stop
}

/// The evidence a `continue` decision must carry for the gate to accept it.
public struct RigEvidence: Sendable, Equatable, Codable {
    /// A render (`render_pose`/`render_clip`) was produced for this step.
    public var hasRender: Bool
    /// A deterministic `assess_motion` measurement, if one could be taken.
    public var measuredMotionQuality: Double?
    /// The subjective vision score in `0...1`, if provided.
    public var subjectiveScore: Double?

    public init(hasRender: Bool, measuredMotionQuality: Double?, subjectiveScore: Double?) {
        self.hasRender = hasRender
        self.measuredMotionQuality = measuredMotionQuality
        self.subjectiveScore = subjectiveScore
    }
}

/// The outcome of running the continue-gate.
public struct RigGateResult: Sendable, Equatable, Codable {
    public var accepted: Bool
    /// Human-readable reasons a `continue` was rejected (empty when accepted or not a continue).
    public var reasons: [String]
    public init(accepted: Bool, reasons: [String]) {
        self.accepted = accepted
        self.reasons = reasons
    }
}

/// The deterministic self-validation gate. A `continue` requires: a render, a motion measurement,
/// `measuredMotionQuality ≥ floor`, and a subjective score ≥ threshold. A missing measurement means
/// the floor isn't enforced for that step (the subjective score still gates). Other decisions pass
/// through (they represent the agent choosing to refine, resolve, request input, or stop).
public enum RigReviewGate {
    public static func evaluate(decision: RigDecision, evidence: RigEvidence,
                                motionQualityFloor: Double = MotionQuality.defaultFloor,
                                subjectiveThreshold: Double = 0.7) -> RigGateResult {
        guard decision == .continue else {
            return RigGateResult(accepted: true, reasons: [])
        }
        var reasons: [String] = []
        if !evidence.hasRender {
            reasons.append("no render — call render_pose/render_clip before continuing")
        }
        if let q = evidence.measuredMotionQuality {
            if q < motionQualityFloor {
                reasons.append("measuredMotionQuality \(q) below floor \(motionQualityFloor)")
            }
        } else {
            reasons.append("no assess_motion measurement — floor not established")
        }
        if let s = evidence.subjectiveScore {
            if s < subjectiveThreshold {
                reasons.append("subjective score \(s) below threshold \(subjectiveThreshold)")
            }
        } else {
            reasons.append("no subjective vision score provided")
        }
        return RigGateResult(accepted: reasons.isEmpty, reasons: reasons)
    }
}
