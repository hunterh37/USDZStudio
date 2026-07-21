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

    /// Whether the **subjective score threshold** is enforced when continuing
    /// *out of* this pass.
    ///
    /// `blockout` only authors coarse geometry at each prim's local origin —
    /// component placement is the `structural` pass's responsibility — so a
    /// blockout render is an origin-collapsed massing whose shape is not yet
    /// judgeable against the reference. `blockout` is therefore exempt from the
    /// score gate (it still owes the full evidence bundle). From `structural`
    /// onward the render is placed and its shape *can* be judged, so the agent's
    /// score is gated on every subsequent pass.
    public var enforcesScoreGate: Bool { self != .blockout }

    /// Whether the **deterministic measured-similarity floor** is enforced when
    /// continuing *out of* this pass.
    ///
    /// The similarity metric blends silhouette IoU with SSIM and luminance
    /// correlation — pixel-intensity comparisons. Passes before `material`
    /// (`blockout`, `structural`, `formRefinement`) author *untextured*
    /// geometry, so their render is a uniform clay/grey shape. Comparing that to
    /// a real, full-colour reference photograph drives SSIM and luminance down
    /// no matter how faithful the geometry is, making the blended floor
    /// unsatisfiable for the geometry passes — a general flaw, not specific to
    /// any one object.
    ///
    /// The floor therefore engages only from `material` — the first pass whose
    /// render carries colour and is genuinely comparable to a colour reference —
    /// and applies through every pass that follows. The geometry passes are
    /// still gated on shape via the subjective score (`enforcesScoreGate`); only
    /// the colour-dependent deterministic floor is deferred to where it is fair.
    public var enforcesSimilarityFloor: Bool { self >= .material }

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
