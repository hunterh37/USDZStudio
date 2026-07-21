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

    /// Whether the fidelity gates (the subjective score threshold *and* the
    /// measured-similarity floor) are enforced when continuing *out of* this
    /// pass.
    ///
    /// The fidelity gates compare the pass render against a *placed* reference.
    /// `blockout` only authors coarse geometry at each prim's local origin —
    /// component placement is the `structural` pass's responsibility — so a
    /// blockout render is an origin-collapsed massing that is not yet
    /// comparable to the reference. Enforcing a similarity floor (or a high
    /// subjective score) there is unsatisfiable for any multi-part object and
    /// would deadlock the pipeline before placement can ever run.
    ///
    /// `blockout` is therefore exempt: continuing out of it still requires the
    /// full evidence bundle (render + comparison sheet + score), but not that
    /// the render *matches*. Fidelity gating begins at `structural` — the first
    /// pass whose render is placed and comparable — and tightens through every
    /// pass that follows.
    public var enforcesFidelityGate: Bool { self != .blockout }

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
    /// The deterministic reference-vs-render similarity measured for this pass
    /// (the verifiable floor under `score`). Decode-defaults to nil for reviews
    /// recorded before the metric existed.
    public var measuredSimilarity: Double?
    public var note: String?

    public init(pass: SculptPass, decision: PassDecision, score: Double? = nil,
                renderPath: String? = nil, comparisonSheetPath: String? = nil,
                measuredSimilarity: Double? = nil, note: String? = nil) {
        self.pass = pass
        self.decision = decision
        self.score = score
        self.renderPath = renderPath
        self.comparisonSheetPath = comparisonSheetPath
        self.measuredSimilarity = measuredSimilarity
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case pass, decision, score, renderPath, comparisonSheetPath, measuredSimilarity, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pass = try c.decode(SculptPass.self, forKey: .pass)
        decision = try c.decode(PassDecision.self, forKey: .decision)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        renderPath = try c.decodeIfPresent(String.self, forKey: .renderPath)
        comparisonSheetPath = try c.decodeIfPresent(String.self, forKey: .comparisonSheetPath)
        measuredSimilarity = try c.decodeIfPresent(Double.self, forKey: .measuredSimilarity)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

extension PassDecision: Equatable {}
