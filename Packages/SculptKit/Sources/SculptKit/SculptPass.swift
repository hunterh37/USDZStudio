import Foundation

/// The eight locked build passes, in strict order. Each pass unlocks only
/// after the previous one is accepted (`PassDecision.continue` with a passing
/// score). Directly mirrors img2threejs's
/// `blockout → structural → form-refinement → material → surface → lighting →
/// interaction → optimization`.
public enum SculptPass: String, Codable, Sendable, CaseIterable, Comparable {
    case blockout
    case structural
    case formRefinement
    case material
    case surface
    case lighting
    case interaction
    case optimization

    /// Position in the locked order (0-based).
    public var index: Int { Self.allCases.firstIndex(of: self)! }

    /// The next pass in the locked order, or nil if this is the last.
    public var next: SculptPass? {
        let i = index + 1
        return i < Self.allCases.count ? Self.allCases[i] : nil
    }

    /// One-line description of what the pass is responsible for authoring.
    public var responsibility: String {
        switch self {
        case .blockout: return "Coarse volumes for every component (rough proportions)."
        case .structural: return "Place components and expand repetition systems."
        case .formRefinement: return "Refine silhouettes and bevels to match the reference."
        case .material: return "Author and bind PBR materials."
        case .surface: return "Surface detail: linework, wear, gloss variation."
        case .lighting: return "Author real UsdLux lights (distant/sphere/rect/dome)."
        case .interaction: return "Sockets, pivots, and colliders for runtime use."
        case .optimization: return "Merge, decimate, and finalize for export."
        }
    }

    public static func < (lhs: SculptPass, rhs: SculptPass) -> Bool {
        lhs.index < rhs.index
    }
}

/// The agent's decision after reviewing a pass's render. Exactly the
/// img2threejs contract.
public enum PassDecision: String, Codable, Sendable {
    /// Accept the pass and unlock the next (requires a render + passing score).
    case `continue`
    /// The spec is wrong/incomplete; rebuild it and re-validate, same pass.
    case refineSpec
    /// The spec is right but the build is off; re-author geometry, same pass.
    case refineCode
    /// Need user clarification before proceeding.
    case requestInput
    /// Halt the pipeline.
    case stop
}

/// A recorded review of one pass: the decision plus the evidence that backs it
/// (render, comparison sheet, vision score).
public struct PassReview: Codable, Sendable, Equatable {
    public var pass: SculptPass
    public var decision: PassDecision
    public var score: Double?
    public var renderPath: String?
    public var comparisonSheetPath: String?
    public var note: String?

    public init(pass: SculptPass, decision: PassDecision, score: Double? = nil,
                renderPath: String? = nil, comparisonSheetPath: String? = nil,
                note: String? = nil) {
        self.pass = pass
        self.decision = decision
        self.score = score
        self.renderPath = renderPath
        self.comparisonSheetPath = comparisonSheetPath
        self.note = note
    }
}

extension PassDecision: Equatable {}
