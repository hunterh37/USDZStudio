import Foundation
import MeshKit
import MechanismKit

/// Severity of a spec-validation issue.
public enum SpecIssueSeverity: String, Sendable, Equatable {
    case error
    case warning
}

/// One problem found in a spec.
public struct SpecIssue: Sendable, Equatable {
    public var severity: SpecIssueSeverity
    public var message: String

    public init(_ severity: SpecIssueSeverity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// The outcome of validating a spec. Schema errors always block; the
/// strict-quality gate additionally blocks specs too shallow for the assessed
/// complexity (img2threejs's `--strict-quality`).
public struct SpecValidationResult: Sendable, Equatable {
    public var issues: [SpecIssue]

    public init(issues: [SpecIssue]) {
        self.issues = issues
    }

    public var errors: [SpecIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [SpecIssue] { issues.filter { $0.severity == .warning } }
    /// Schema-valid: no error-severity issues.
    public var isValid: Bool { errors.isEmpty }
}

/// Validates an `ObjectSculptSpec` for schema correctness and, optionally,
/// against the strict-quality bar implied by a `PreSpecAssessment`.
public enum SpecValidator {

    public static func validate(
        _ spec: ObjectSculptSpec,
        assessment: PreSpecAssessment? = nil,
        strictQuality: Bool = false
    ) -> SpecValidationResult {
        var issues: [SpecIssue] = []

        // ── Schema checks (always) ────────────────────────────────────────
        if spec.name.isEmpty {
            issues.append(.init(.error, "spec name must not be empty"))
        }

        let materialIDs = spec.materialIDs
        if materialIDs.count != spec.materials.count {
            issues.append(.init(.error, "duplicate material ids in spec"))
        }
        for material in spec.materials {
            issues.append(contentsOf: colorIssues(material.baseColor, label: "material '\(material.id)' baseColor"))
            if let emissive = material.emissive {
                issues.append(contentsOf: colorIssues(emissive, label: "material '\(material.id)' emissive"))
            }
            if material.roughness < 0 || material.roughness > 1 {
                issues.append(.init(.error, "material '\(material.id)' roughness must be in 0...1"))
            }
            if material.metallic < 0 || material.metallic > 1 {
                issues.append(.init(.error, "material '\(material.id)' metallic must be in 0...1"))
            }
            issues.append(contentsOf: textureIssues(material))
        }

        var seenNames = Set<String>()
        for node in spec.allNodes {
            issues.append(contentsOf: nodeIssues(node, materialIDs: materialIDs))
            if !seenNames.insert(node.name).inserted {
                issues.append(.init(.error, "duplicate component name '\(node.name)'"))
            }
        }

        // Runtime-layer schema: colliders/destruction groups must reference
        // real components and be well-formed.
        issues.append(contentsOf: runtimeSchemaIssues(spec, componentNames: seenNames))

        // Surface-projection + character-landmark schema (always).
        issues.append(contentsOf: surfaceSchemaIssues(spec, componentNames: seenNames))
        issues.append(contentsOf: landmarkSchemaIssues(spec, componentNames: seenNames))

        // Lighting + LOD schema (always).
        issues.append(contentsOf: lightSchemaIssues(spec))
        issues.append(contentsOf: lodSchemaIssues(spec))
        issues.append(contentsOf: optimizationIssues(spec))

        // ── Strict-quality gate (opt-in) ──────────────────────────────────
        if strictQuality {
            issues.append(contentsOf: strictQualityIssues(spec, assessment: assessment))
        }

        return SpecValidationResult(issues: issues)
    }

    // MARK: - Schema helpers

    static func colorIssues(_ color: [Double], label: String) -> [SpecIssue] {
        guard color.count == 3 else {
            return [.init(.error, "\(label) must be [r, g, b]")]
        }
        // A non-finite (NaN/±inf) component is neither < 0 nor > 1, so it would
        // slip past a bare range comparison and be authored onto the stage.
        if color.contains(where: { !$0.isFinite || $0 < 0 || $0 > 1 }) {
            return [.init(.error, "\(label) components must be in 0...1")]
        }
        return []
    }

    static func nodeIssues(_ node: ComponentNode, materialIDs: Set<String>) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        if !PrimName.isValid(node.name) {
            issues.append(.init(.error, "component name '\(node.name)' is not a valid USD identifier"))
        }
        for (vec, label) in [(node.translation, "translation"), (node.rotationEulerDegrees, "rotation"), (node.scale, "scale")] {
            if vec.count != 3 {
                issues.append(.init(.error, "component '\(node.name)' \(label) must be [x, y, z]"))
            }
        }
        if node.scale.count == 3, node.scale.contains(0) {
            issues.append(.init(.error, "component '\(node.name)' scale has a zero component"))
        }
        if let materialID = node.materialID, !materialIDs.contains(materialID) {
            issues.append(.init(.error, "component '\(node.name)' references unknown material '\(materialID)'"))
        }
        if case .library(let entryID) = node.shape, ShapeLibrary.entry(id: entryID) == nil {
            issues.append(.init(.error, "component '\(node.name)' references unknown library entry '\(entryID)'"))
        }
        if node.shape.authorsGeometry {
            if node.width <= 0 || node.height <= 0 || node.depth <= 0 || node.radius <= 0 {
                issues.append(.init(.error, "component '\(node.name)' dimensions must be positive"))
            }
            if node.segments < 3 {
                issues.append(.init(.error, "component '\(node.name)' segments must be >= 3"))
            }
        }
        if let repetition = node.repetition {
            if repetition.count < 1 {
                issues.append(.init(.error, "component '\(node.name)' repetition count must be >= 1"))
            }
            if repetition.step.count != 3 {
                issues.append(.init(.error, "component '\(node.name)' repetition step must be [x, y, z]"))
            }
        }
        issues.append(contentsOf: refinementIssues(node))
        return issues
    }

    /// Validate a node's declared geometry refinements. Refinements only apply
    /// to geometry-authoring nodes, and `inset` requires a fraction in (0, 1)
    /// and a finite depth (matching MeshKit's `InsetFaces` preconditions).
    static func refinementIssues(_ node: ComponentNode) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        if !node.refinements.isEmpty, !node.shape.authorsGeometry {
            issues.append(.init(.error, "component '\(node.name)' is a group but declares refinements"))
        }
        for refinement in node.refinements {
            switch refinement {
            case let .inset(fraction, depth):
                if !fraction.isFinite || fraction <= 0 || fraction >= 1 {
                    issues.append(.init(.error, "component '\(node.name)' inset fraction must be in (0, 1)"))
                }
                if !depth.isFinite {
                    issues.append(.init(.error, "component '\(node.name)' inset depth must be finite"))
                }
            case let .subdivide(levels):
                if levels < 1 {
                    issues.append(.init(.error, "component '\(node.name)' subdivide levels must be ≥ 1"))
                }
            case let .taper(_, scale):
                // scale 1 is a no-op; 0/negative collapses the lattice layer.
                if !scale.isFinite || scale <= 0 || scale == 1 {
                    issues.append(.init(.error, "component '\(node.name)' taper scale must be finite, > 0, and ≠ 1"))
                }
            case let .bevel(width, angleDegrees):
                if !width.isFinite || width <= 0 {
                    issues.append(.init(.error, "component '\(node.name)' bevel width must be > 0"))
                }
                if !angleDegrees.isFinite || angleDegrees <= 0 || angleDegrees >= 180 {
                    issues.append(.init(.error, "component '\(node.name)' bevel angle must be in (0, 180)"))
                }
            case let .extrude(_, distance):
                if !distance.isFinite || distance == 0 {
                    issues.append(.init(.error, "component '\(node.name)' extrude distance must be finite and non-zero"))
                }
            }
        }
        return issues
    }

    /// Validate the optimization spec: a declared weld distance must be finite
    /// and positive (MeshKit's `MergeVertices.byDistance` precondition).
    static func optimizationIssues(_ spec: ObjectSculptSpec) -> [SpecIssue] {
        guard let optimization = spec.optimization else { return [] }
        if !optimization.weldDistance.isFinite || optimization.weldDistance <= 0 {
            return [.init(.error, "optimization weldDistance must be finite and > 0")]
        }
        return []
    }

    // MARK: - Runtime-layer schema

    static func runtimeSchemaIssues(_ spec: ObjectSculptSpec, componentNames: Set<String>) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        for collider in spec.colliders {
            if !componentNames.contains(collider.component) {
                issues.append(.init(.error, "collider '\(collider.name)' references unknown component '\(collider.component)'"))
            }
            if collider.center.count != 3 || collider.size.count != 3 {
                issues.append(.init(.error, "collider '\(collider.name)' center and size must be [x, y, z]"))
            } else if collider.size.contains(where: { $0 <= 0 }) {
                issues.append(.init(.error, "collider '\(collider.name)' size components must be positive"))
            }
        }
        for group in spec.destructionGroups {
            if group.members.isEmpty {
                issues.append(.init(.error, "destruction group '\(group.name)' has no members"))
            }
            for member in group.members where !componentNames.contains(member) {
                issues.append(.init(.error, "destruction group '\(group.name)' references unknown component '\(member)'"))
            }
        }
        var jointNames = Set<String>()
        for joint in spec.joints {
            if !jointNames.insert(joint.name).inserted {
                issues.append(.init(.error, "duplicate joint name '\(joint.name)'"))
            }
            if !componentNames.contains(joint.target) {
                issues.append(.init(.error, "joint '\(joint.name)' targets unknown component '\(joint.target)'"))
            }
            // Delegate schema/geometry checks to MechanismKit's invariant layer.
            for issue in JointInvariants.validate(joint) where issue.severity == .error {
                issues.append(.init(.error, issue.message))
            }
        }
        return issues
    }

    // MARK: - Material texture schema

    /// Validate the optional texture channels: every declared map path must be
    /// non-empty, and `normalScale` (when present) must be >= 0.
    static func textureIssues(_ material: MaterialSpec) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        let maps: [(String?, String)] = [
            (material.albedoMap, "albedoMap"), (material.normalMap, "normalMap"),
            (material.roughnessMap, "roughnessMap"), (material.emissiveMap, "emissiveMap"),
        ]
        for (path, label) in maps where path != nil {
            if path!.isEmpty {
                issues.append(.init(.error, "material '\(material.id)' \(label) path must not be empty"))
            }
        }
        // `!isFinite` guards NaN/±inf, which a bare `< 0` comparison misses.
        if let scale = material.normalScale, !scale.isFinite || scale < 0 {
            issues.append(.init(.error, "material '\(material.id)' normalScale must be >= 0"))
        }
        return issues
    }

    // MARK: - Surface-projection schema

    static func surfaceSchemaIssues(_ spec: ObjectSculptSpec, componentNames: Set<String>) -> [SpecIssue] {
        guard let projection = spec.surfaceProjection else { return [] }
        var issues: [SpecIssue] = []
        if !componentNames.contains(projection.targetComponent) {
            issues.append(.init(.error, "surface projection references unknown component '\(projection.targetComponent)'"))
        }
        if projection.uvSet.isEmpty {
            issues.append(.init(.error, "surface projection uvSet must not be empty"))
        }
        for (vec, label) in [(projection.camera.position, "camera position"),
                             (projection.camera.target, "camera target"),
                             (projection.camera.up, "camera up")] {
            if vec.count != 3 {
                issues.append(.init(.error, "surface projection \(label) must be [x, y, z]"))
            } else if vec.contains(where: { !$0.isFinite }) {
                issues.append(.init(.error, "surface projection \(label) must be finite"))
            }
        }
        return issues
    }

    // MARK: - Character-landmark schema

    static func landmarkSchemaIssues(_ spec: ObjectSculptSpec, componentNames: Set<String>) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        for landmark in spec.landmarks {
            if !componentNames.contains(landmark.component) {
                issues.append(.init(.error, "landmark '\(landmark.name)' references unknown component '\(landmark.component)'"))
            }
            if landmark.position.count != 3 {
                issues.append(.init(.error, "landmark '\(landmark.name)' position must be [x, y, z]"))
            } else if landmark.position.contains(where: { !$0.isFinite }) {
                issues.append(.init(.error, "landmark '\(landmark.name)' position must be finite"))
            }
        }
        return issues
    }

    // MARK: - Lighting schema

    /// Validate authored lights: unique USD-valid names, finite non-negative
    /// intensity, an RGB colour in 0...1, and [x,y,z] transform vectors.
    static func lightSchemaIssues(_ spec: ObjectSculptSpec) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        var seen = Set<String>()
        for light in spec.lights {
            if !PrimName.isValid(light.name) {
                issues.append(.init(.error, "light name '\(light.name)' is not a valid USD identifier"))
            }
            if !seen.insert(light.name).inserted {
                issues.append(.init(.error, "duplicate light name '\(light.name)'"))
            }
            if !light.intensity.isFinite || light.intensity < 0 {
                issues.append(.init(.error, "light '\(light.name)' intensity must be finite and >= 0"))
            }
            issues.append(contentsOf: colorIssues(light.color, label: "light '\(light.name)' color"))
            for (vec, label) in [(light.translation, "translation"), (light.rotationEulerDegrees, "rotation")] {
                if vec.count != 3 {
                    issues.append(.init(.error, "light '\(light.name)' \(label) must be [x, y, z]"))
                } else if vec.contains(where: { !$0.isFinite }) {
                    issues.append(.init(.error, "light '\(light.name)' \(label) must be finite"))
                }
            }
        }
        return issues
    }

    // MARK: - LOD schema

    /// Validate LOD tiers: non-empty names, a screen-coverage threshold in
    /// 0...1, and a decimation fraction in (0, 1].
    static func lodSchemaIssues(_ spec: ObjectSculptSpec) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        for tier in spec.lodTiers {
            if tier.name.isEmpty {
                issues.append(.init(.error, "LOD tier name must not be empty"))
            }
            if !tier.screenCoverage.isFinite || tier.screenCoverage < 0 || tier.screenCoverage > 1 {
                issues.append(.init(.error, "LOD tier '\(tier.name)' screenCoverage must be in 0...1"))
            }
            if !tier.decimation.isFinite || tier.decimation <= 0 || tier.decimation > 1 {
                issues.append(.init(.error, "LOD tier '\(tier.name)' decimation must be in (0, 1]"))
            }
        }
        return issues
    }

    // MARK: - Feature-acceptance gate

    /// img2threejs's per-feature acceptance policy: every detail item that
    /// declares a `minScore` must carry a recorded score that meets it. Used as
    /// a completion gate (checked on `continue` in the final pass), so a
    /// high-value feature can't slip through underscored.
    public static func featureAcceptance(_ spec: ObjectSculptSpec) -> SpecValidationResult {
        var issues: [SpecIssue] = []
        for item in spec.detailInventory.unaccepted {
            let recorded = item.score.map { "\($0)" } ?? "no score"
            issues.append(.init(.error,
                "feature '\(item.id)' below acceptance threshold (\(recorded) < \(item.minScore!))"))
        }
        return SpecValidationResult(issues: issues)
    }

    /// Geometry components (excluding the root) that have not declared an
    /// `attachment`. Surfaced as an authoring warning by `sculpt_author_spec`
    /// so the effectively-required field isn't a surprise that only strict
    /// validate rejects — and then all at once (issue #113). The strict gate
    /// (`attachmentIssues`) still enforces it; this only warns earlier.
    public static func componentsMissingAttachment(_ spec: ObjectSculptSpec) -> [String] {
        let rootName = spec.root.name
        return spec.allNodes
            .filter { $0.name != rootName && $0.shape.authorsGeometry && $0.attachment == nil }
            .map(\.name)
    }

    // MARK: - Action-ready gate

    /// img2threejs's "Action-Ready Gate": confirms the object exposes a usable
    /// runtime layer (at least one socket or collider). Schema correctness of
    /// the runtime references is covered by `validate`; this checks presence.
    public static func actionReady(_ spec: ObjectSculptSpec) -> SpecValidationResult {
        let manifest = RuntimeManifest(spec: spec)
        var issues: [SpecIssue] = []
        if !manifest.isActionable {
            issues.append(.init(.error, "action-ready: object exposes no runtime handles — author at least one socket, collider, or joint"))
        }
        return SpecValidationResult(issues: issues)
    }

    // MARK: - Strict-quality helpers

    static func strictQualityIssues(_ spec: ObjectSculptSpec, assessment: PreSpecAssessment?) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        let inventory = spec.detailInventory

        if !inventory.isFullyMapped {
            let names = inventory.unmapped.map(\.id).joined(separator: ", ")
            issues.append(.init(.error, "strict-quality: \(inventory.unmapped.count) detail item(s) unmapped: \(names)"))
        }

        // Character track: a character spec must declare proportion-lock
        // landmarks so its proportions stay deterministic across rebuilds.
        if spec.objectClass == .character, spec.landmarks.isEmpty {
            issues.append(.init(.error, "strict-quality: character spec declares no proportion-lock landmarks"))
        }

        // Attachment correctness ("nothing floats mid-air"): every geometry
        // component other than the root must declare how it joins its parent,
        // and none may be explicitly `.free`.
        issues.append(contentsOf: attachmentIssues(spec))

        guard let policy = assessment?.policy else {
            // Without an assessment we can only enforce mapping; note it.
            issues.append(.init(.warning, "strict-quality: no assessment supplied — only detail-mapping enforced"))
            return issues
        }

        if inventory.items.count < policy.minDetailItems {
            issues.append(.init(.error, "strict-quality: \(inventory.items.count) detail items < required \(policy.minDetailItems) for complexity \(assessment!.complexity)"))
        }
        if spec.componentCount < policy.minComponents {
            issues.append(.init(.error, "strict-quality: \(spec.componentCount) components < required \(policy.minComponents)"))
        }
        if policy.requireMaterials {
            if spec.materials.isEmpty {
                issues.append(.init(.error, "strict-quality: spec has no materials but the assessment requires them"))
            }
            let unpainted = spec.geometryLeaves.filter { $0.materialID == nil }
            if !unpainted.isEmpty {
                let names = unpainted.map(\.name).joined(separator: ", ")
                issues.append(.init(.error, "strict-quality: geometry leaves without a material: \(names)"))
            }
        }
        return issues
    }

    // MARK: - Attachment correctness

    /// Every geometry component other than the root must declare a join method
    /// (`attachment`) and it must not be `.free`. Groups are structural and
    /// exempt; the root grounds the object and needs no parent join.
    static func attachmentIssues(_ spec: ObjectSculptSpec) -> [SpecIssue] {
        var issues: [SpecIssue] = []
        let rootName = spec.root.name
        for node in spec.allNodes where node.name != rootName && node.shape.authorsGeometry {
            switch node.attachment {
            case .none:
                issues.append(.init(.error, "strict-quality: component '\(node.name)' floats — declare an attachment (weld/socket/pin/root)"))
            case .free:
                issues.append(.init(.error, "strict-quality: component '\(node.name)' is attachment '.free' — it floats mid-air"))
            default:
                break
            }
        }
        return issues
    }
}

/// Minimal USD-identifier check, local to SculptKit so the module stays a pure
/// leaf (USDCore's `PrimPath.isValidName` is not surfaced for bare names here).
enum PrimName {
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
