import Foundation

/// What kind of object the reference depicts. Drives the acceptance policy —
/// characters demand higher detail budgets than props.
public enum ObjectClass: String, Codable, Sendable, CaseIterable {
    case character
    case object
    case hybrid
}

/// Per-object acceptance thresholds, derived from the pre-spec assessment.
/// The strict-quality gate checks the spec against these before any build
/// pass unlocks.
public struct FeatureAcceptancePolicy: Codable, Sendable, Equatable {
    /// Minimum vision score (0...1) a pass must clear to `continue`.
    public var minScore: Double
    /// Minimum number of enumerated detail items the inventory must hold.
    public var minDetailItems: Int
    /// Minimum component-tree node count for a spec of this complexity.
    public var minComponents: Int
    /// Whether every geometry leaf must have a bound material.
    public var requireMaterials: Bool

    public init(minScore: Double, minDetailItems: Int, minComponents: Int,
                requireMaterials: Bool) {
        self.minScore = minScore
        self.minDetailItems = minDetailItems
        self.minComponents = minComponents
        self.requireMaterials = requireMaterials
    }
}

/// Whether a reference is usable for reconstruction at all. img2threejs's
/// first quality gate ("Suitability Gate") — it can reject an input outright
/// or ask for more before any spec work begins.
public enum Suitability: String, Codable, Sendable {
    /// Good enough to author a spec against.
    case viable
    /// Usable, but the agent should gather more (extra hints/views) first.
    case needsMoreInput
    /// Not reconstructable — too small / degenerate; halt.
    case rejected
}

/// The suitability verdict plus the reasons behind it.
public struct SuitabilityVerdict: Codable, Sendable, Equatable {
    public var suitability: Suitability
    public var reasons: [String]

    public init(_ suitability: Suitability, reasons: [String] = []) {
        self.suitability = suitability
        self.reasons = reasons
    }

    /// True only when the reference is `viable`.
    public var isViable: Bool { suitability == .viable }
}

/// The pre-spec assessment: judge suitability, classify the object, score its
/// complexity, and establish the acceptance policy — all deterministically
/// from lightweight hints (no image decoding here; the agent supplies
/// descriptive hints and the image dimensions).
public struct PreSpecAssessment: Codable, Sendable, Equatable {
    /// The suitability gate verdict (see `Suitability`).
    public var suitability: SuitabilityVerdict
    public var objectClass: ObjectClass
    /// 1 (trivial prop) … 5 (highly detailed character).
    public var complexity: Int
    public var policy: FeatureAcceptancePolicy
    public var notes: [String]

    public init(suitability: SuitabilityVerdict = .init(.viable),
                objectClass: ObjectClass, complexity: Int,
                policy: FeatureAcceptancePolicy, notes: [String] = []) {
        self.suitability = suitability
        self.objectClass = objectClass
        self.complexity = complexity
        self.policy = policy
        self.notes = notes
    }

    /// Keywords that, when present in the hints, classify the object.
    static let characterKeywords: Set<String> = [
        "character", "person", "figure", "humanoid", "creature", "animal",
        "robot", "mascot", "face", "body",
    ]

    /// Deterministically assess an object from descriptive hints and the
    /// reference image's pixel dimensions.
    ///
    /// - Parameters:
    ///   - hints: free-form descriptive tags (e.g. "wooden barrel", "rusty
    ///     bevels", "glossy").
    ///   - width/height: reference image dimensions in pixels (larger images
    ///     get a small complexity bump — more visible detail).
    public static func assess(hints: [String], width: Int, height: Int) -> PreSpecAssessment {
        let lowered = hints.map { $0.lowercased() }
        let joined = lowered.joined(separator: " ")

        let isCharacter = characterKeywords.contains { joined.contains($0) }
        let objectClass: ObjectClass
        if isCharacter {
            objectClass = hints.count >= 4 ? .hybrid : .character
        } else {
            objectClass = .object
        }

        // Complexity: base on hint count, bumped for characters and large refs.
        var complexity = min(5, max(1, 1 + hints.count / 2))
        if isCharacter { complexity = min(5, complexity + 1) }
        if width * height >= 1_048_576 { complexity = min(5, complexity + 1) }

        let policy = FeatureAcceptancePolicy(
            minScore: isCharacter ? 0.8 : 0.7,
            minDetailItems: complexity,
            minComponents: max(2, complexity),
            requireMaterials: complexity >= 2)

        var notes = ["classified as \(objectClass.rawValue)", "complexity \(complexity)"]
        if hints.isEmpty { notes.append("no hints supplied — assessment is conservative") }

        return PreSpecAssessment(
            suitability: suitability(hints: hints, width: width, height: height, isCharacter: isCharacter),
            objectClass: objectClass, complexity: complexity,
            policy: policy, notes: notes)
    }

    /// The suitability gate. Rejects references too small to carry
    /// identity-defining detail, and asks for more input when the description
    /// is too thin to author confidently (no hints, or a character described
    /// by a single hint).
    static func suitability(hints: [String], width: Int, height: Int, isCharacter: Bool) -> SuitabilityVerdict {
        var reasons: [String] = []
        if min(width, height) < 64 {
            reasons.append("reference is \(width)×\(height)px — too small (min 64px per side) to reconstruct")
            return SuitabilityVerdict(.rejected, reasons: reasons)
        }
        if hints.isEmpty {
            reasons.append("no descriptive hints — supply a few before authoring a spec")
        } else if isCharacter && hints.count < 2 {
            reasons.append("character references need more than one hint (pose, proportions, distinctive features)")
        }
        return reasons.isEmpty
            ? SuitabilityVerdict(.viable)
            : SuitabilityVerdict(.needsMoreInput, reasons: reasons)
    }
}
