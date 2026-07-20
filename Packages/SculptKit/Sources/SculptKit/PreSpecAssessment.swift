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

/// The pre-spec assessment: classify the object, score its complexity, and
/// establish the acceptance policy — all deterministically from lightweight
/// hints (no image decoding here; the agent supplies descriptive hints and the
/// image dimensions).
public struct PreSpecAssessment: Codable, Sendable, Equatable {
    public var objectClass: ObjectClass
    /// 1 (trivial prop) … 5 (highly detailed character).
    public var complexity: Int
    public var policy: FeatureAcceptancePolicy
    public var notes: [String]

    public init(objectClass: ObjectClass, complexity: Int,
                policy: FeatureAcceptancePolicy, notes: [String] = []) {
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
            objectClass: objectClass, complexity: complexity,
            policy: policy, notes: notes)
    }
}
