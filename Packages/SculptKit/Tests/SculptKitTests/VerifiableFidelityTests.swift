import Foundation
import Testing
@testable import SculptKit

/// Covers the new verifiable-fidelity plumbing added to SculptKit: the
/// similarity floor in the orchestrator, real form-refinement + optimization
/// build steps, their validation, the multi-view comparison sheet, and the
/// decode-defaults that keep old specs/policies loading.
@Suite struct VerifiableFidelityTests {

    // MARK: - Orchestrator similarity floor

    func passingReview(pass: SculptPass = .material, similarity: Double? = nil) -> PassReview {
        PassReview(pass: pass, decision: .continue, score: 0.95,
                   renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png",
                   measuredSimilarity: similarity)
    }

    /// An orchestrator advanced to `material` — the first pass the similarity
    /// floor gates (blockout/structural/formRefinement are untextured, so the
    /// colour-dependent floor is deferred). Each prior step clears its score
    /// gate with a passing score + evidence.
    func orchestratorAtMaterial() throws -> PassOrchestrator {
        var orchestrator = PassOrchestrator()
        while orchestrator.current != .material {
            _ = try orchestrator.advance(
                after: PassReview(pass: orchestrator.current, decision: .continue, score: 0.95,
                                  renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png"),
                threshold: 0.7, similarityFloor: 0.5)
        }
        return orchestrator
    }

    @Test func floorOfZeroKeepsLegacyBehaviour() throws {
        var orchestrator = try orchestratorAtMaterial()
        // No measuredSimilarity, floor 0 → advances just like before.
        let result = try orchestrator.advance(after: passingReview(), threshold: 0.7, similarityFloor: 0)
        #expect(result == .advanced(to: .surface))
    }

    @Test func floorRequiresMeasuredSimilarity() throws {
        var orchestrator = try orchestratorAtMaterial()
        #expect(throws: AdvanceError.continueRequiresMeasuredSimilarity) {
            try orchestrator.advance(after: passingReview(), threshold: 0.7, similarityFloor: 0.5)
        }
    }

    @Test func floorRejectsLowSimilarity() throws {
        var orchestrator = try orchestratorAtMaterial()
        #expect(throws: AdvanceError.similarityBelowFloor(measured: 0.3, floor: 0.5)) {
            try orchestrator.advance(after: passingReview(similarity: 0.3), threshold: 0.7, similarityFloor: 0.5)
        }
    }

    @Test func floorAcceptsSufficientSimilarity() throws {
        var orchestrator = try orchestratorAtMaterial()
        let result = try orchestrator.advance(
            after: passingReview(similarity: 0.72), threshold: 0.7, similarityFloor: 0.5)
        #expect(result == .advanced(to: .surface))
    }

    @Test func geometryPassesDeferFloor() throws {
        // structural + formRefinement are untextured: even with a floor set, a
        // passing score with NO measured similarity advances (floor deferred).
        var orchestrator = PassOrchestrator()
        _ = try orchestrator.advance(after: passingReview(pass: .blockout), threshold: 0.7, similarityFloor: 0.5)
        #expect(orchestrator.current == .structural)
        _ = try orchestrator.advance(after: passingReview(pass: .structural), threshold: 0.7, similarityFloor: 0.5)
        #expect(orchestrator.current == .formRefinement)
        _ = try orchestrator.advance(after: passingReview(pass: .formRefinement), threshold: 0.7, similarityFloor: 0.5)
        #expect(orchestrator.current == .material)
    }

    @Test func floorErrorsHaveDescriptions() {
        #expect(!AdvanceError.continueRequiresMeasuredSimilarity.description.isEmpty)
        #expect(AdvanceError.similarityBelowFloor(measured: 0.1, floor: 0.5).description.contains("0.5"))
    }

    @Test func assessmentSetsFloorAndCompliance() {
        let object = PreSpecAssessment.assess(hints: ["barrel"], width: 512, height: 512)
        #expect(object.policy.similarityFloor == 0.5)
        #expect(object.policy.requireCompliance == true)
        let character = PreSpecAssessment.assess(hints: ["character", "hero"], width: 512, height: 512)
        #expect(character.policy.similarityFloor == 0.55)
    }

    // MARK: - Form-refinement build steps

    static func refinedSpec(_ refinements: [MeshRefinement]) -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box),
                                 attachment: .weld, refinements: refinements)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        return ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
    }

    @Test func formRefinementEmitsRealOpsWhenDeclared() {
        let spec = Self.refinedSpec([.inset(fraction: 0.3, depth: -0.1)])
        let steps = BuildPlanner.plan(for: spec, pass: .formRefinement)
        #expect(steps.count == 1)
        guard case .refineMesh(let path, let ops) = steps[0] else { Issue.record("expected refineMesh"); return }
        #expect(path == "/Obj/Body")
        #expect(ops == [.inset(fraction: 0.3, depth: -0.1)])
    }

    @Test func formRefinementStaysReviewOnlyWithoutRefinements() {
        let spec = Self.refinedSpec([])
        #expect(BuildPlanner.plan(for: spec, pass: .formRefinement).isEmpty)
    }

    @Test func formRefinementExpandsRepetitionCopies() {
        let slat = ComponentNode(name: "Slat", shape: .primitive(.box), attachment: .weld,
                                 refinements: [.inset(fraction: 0.2, depth: 0)],
                                 children: [])
        var node = slat
        node.repetition = RepetitionSystem(name: "s", count: 3, step: [1, 0, 0])
        let root = ComponentNode(name: "Obj", shape: .group, children: [node])
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        let steps = BuildPlanner.plan(for: spec, pass: .formRefinement)
        // Base + 2 copies each get a refine step.
        #expect(steps.count == 3)
    }

    // MARK: - Optimization build steps

    static func optimizedSpec(weld: Double?, tiers: [LODTier]) -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            lodTiers: tiers,
            optimization: weld.map { OptimizationSpec(weldDistance: $0) })
    }

    @Test func optimizationEmitsDecimateAndLOD() {
        let spec = Self.optimizedSpec(weld: 0.01, tiers: [LODTier(name: "lo", screenCoverage: 0.2, decimation: 0.3)])
        let steps = BuildPlanner.plan(for: spec, pass: .optimization)
        #expect(steps.count == 2)
        guard case .decimateMesh(let path, let dist) = steps[0] else { Issue.record("expected decimateMesh"); return }
        #expect(path == "/Obj/Body")
        #expect(dist == 0.01)
        guard case .authorLOD = steps[1] else { Issue.record("expected authorLOD"); return }
    }

    @Test func optimizationDecimatesWithoutTiers() {
        let spec = Self.optimizedSpec(weld: 0.02, tiers: [])
        let steps = BuildPlanner.plan(for: spec, pass: .optimization)
        #expect(steps.count == 1)
        guard case .decimateMesh = steps[0] else { Issue.record("expected decimateMesh"); return }
    }

    @Test func optimizationAuthorsLODWithoutWeld() {
        let spec = Self.optimizedSpec(weld: nil, tiers: [LODTier(name: "lo", screenCoverage: 0.2, decimation: 0.3)])
        let steps = BuildPlanner.plan(for: spec, pass: .optimization)
        #expect(steps.count == 1)
        guard case .authorLOD = steps[0] else { Issue.record("expected authorLOD"); return }
    }

    @Test func optimizationEmptyWhenNothingDeclared() {
        let spec = Self.optimizedSpec(weld: nil, tiers: [])
        #expect(BuildPlanner.plan(for: spec, pass: .optimization).isEmpty)
    }

    @Test func optimizationIgnoresNonPositiveWeld() {
        let spec = Self.optimizedSpec(weld: 0, tiers: [])
        #expect(BuildPlanner.plan(for: spec, pass: .optimization).isEmpty)
    }

    // MARK: - Validation of new fields

    @Test func validRefinementPasses() {
        let spec = Self.refinedSpec([.inset(fraction: 0.3, depth: 0)])
        #expect(SpecValidator.validate(spec).isValid)
    }

    @Test func rejectsRefinementOnGroup() {
        var root = ComponentNode(name: "Obj", shape: .group,
                                 children: [ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld)])
        root.refinements = [.inset(fraction: 0.3, depth: 0)]
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        let result = SpecValidator.validate(spec)
        #expect(result.errors.contains { $0.message.contains("group but declares refinements") })
    }

    @Test func rejectsBadInsetFraction() {
        for bad in [0.0, 1.0, -0.2, Double.nan] {
            let spec = Self.refinedSpec([.inset(fraction: bad, depth: 0)])
            #expect(!SpecValidator.validate(spec).isValid)
        }
    }

    @Test func rejectsNonFiniteInsetDepth() {
        let spec = Self.refinedSpec([.inset(fraction: 0.3, depth: .infinity)])
        #expect(!SpecValidator.validate(spec).isValid)
    }

    @Test func rejectsBadWeldDistance() {
        for bad in [0.0, -1.0, Double.nan] {
            let spec = Self.optimizedSpec(weld: bad, tiers: [])
            #expect(!SpecValidator.validate(spec).isValid)
        }
    }

    @Test func acceptsPositiveWeldDistance() {
        let spec = Self.optimizedSpec(weld: 0.01, tiers: [])
        #expect(SpecValidator.optimizationIssues(spec).isEmpty)
    }

    @Test func noOptimizationSpecHasNoIssues() {
        let spec = Self.optimizedSpec(weld: nil, tiers: [])
        #expect(SpecValidator.optimizationIssues(spec).isEmpty)
    }

    // MARK: - Multi-view comparison sheet

    @Test func multiViewSheetRendersEveryRow() {
        let views = [
            ComparisonView(label: "front", referencePath: "/tmp/f_ref.png", renderPath: "/tmp/f_out.png"),
            ComparisonView(label: "side", referencePath: "/tmp/s_ref.png", renderPath: "/tmp/s_out.png"),
        ]
        let sheet = ComparisonSheet(pass: .material, views: views, size: 128)
        let svg = sheet.svg()
        #expect(svg.contains("2 views"))
        #expect(svg.contains("front — reference"))
        #expect(svg.contains("side — render"))
        #expect(svg.contains("file:///tmp/f_ref.png"))
        #expect(svg.contains("file:///tmp/s_out.png"))
        // Height grows with row count: header + 2 * (size + label band).
        #expect(svg.contains("height=\"\(28 + 2 * (128 + 22))\""))
    }

    @Test func singleViewConvenienceStillWorks() {
        let sheet = ComparisonSheet(pass: .blockout, referencePath: "a", renderPath: "b")
        #expect(sheet.views.count == 1)
        #expect(sheet.svg().contains("1 view"))
    }

    @Test func labelSpecialCharactersAreEscaped() {
        let sheet = ComparisonSheet(pass: .blockout, views: [
            ComparisonView(label: "a<b>&c", referencePath: "r", renderPath: "o")])
        let svg = sheet.svg()
        #expect(svg.contains("a&lt;b&gt;&amp;c"))
    }

    // MARK: - Codable back-compat

    @Test func legacyPolicyDecodesWithoutNewFields() throws {
        let legacy = #"{"minScore":0.7,"minDetailItems":2,"minComponents":2,"requireMaterials":true}"#
        let policy = try JSONDecoder().decode(FeatureAcceptancePolicy.self, from: Data(legacy.utf8))
        #expect(policy.similarityFloor == 0)
        #expect(policy.requireCompliance == false)
    }

    @Test func legacyReviewDecodesWithoutMeasuredSimilarity() throws {
        let legacy = #"{"pass":"blockout","decision":"continue","score":0.9}"#
        let review = try JSONDecoder().decode(PassReview.self, from: Data(legacy.utf8))
        #expect(review.measuredSimilarity == nil)
        #expect(review.score == 0.9)
    }

    @Test func legacyNodeDecodesWithoutRefinements() throws {
        // Encode a node, strip the new `refinements` key, and confirm it still
        // decodes (with refinements defaulting to []).
        let node = ComponentNode(name: "Body", shape: .primitive(.box))
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(node)) as! [String: Any]
        object.removeValue(forKey: "refinements")
        let data = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONDecoder().decode(ComponentNode.self, from: data)
        #expect(back.refinements.isEmpty)
        #expect(back.scale == [1, 1, 1])
    }

    @Test func specRoundTripsWithNewFields() throws {
        let spec = Self.optimizedSpec(weld: 0.01, tiers: [LODTier(name: "lo", screenCoverage: 0.2, decimation: 0.3)])
        var withRefinement = spec
        withRefinement.root.children[0].refinements = [.inset(fraction: 0.25, depth: -0.05)]
        let data = try withRefinement.encoded()
        let back = try ObjectSculptSpec.decoded(from: data)
        #expect(back == withRefinement)
        #expect(back.optimization?.weldDistance == 0.01)
        #expect(back.root.children[0].refinements == [.inset(fraction: 0.25, depth: -0.05)])
    }

    @Test func orchestratorRoundTrips() throws {
        var orchestrator = PassOrchestrator()
        try orchestrator.advance(after: passingReview(similarity: 0.9), threshold: 0.7, similarityFloor: 0.5)
        let data = try JSONEncoder().encode(orchestrator)
        let back = try JSONDecoder().decode(PassOrchestrator.self, from: data)
        #expect(back == orchestrator)
        #expect(back.current == .structural)
    }

    @Test func refinementRoundTrips() throws {
        let op = MeshRefinement.inset(fraction: 0.4, depth: 0.2)
        let data = try JSONEncoder().encode(op)
        #expect(try JSONDecoder().decode(MeshRefinement.self, from: data) == op)
    }

    @Test func refinementInsetDepthDefaultsToZero() throws {
        let json = #"{"kind":"inset","fraction":0.3}"#
        let op = try JSONDecoder().decode(MeshRefinement.self, from: Data(json.utf8))
        #expect(op == .inset(fraction: 0.3, depth: 0))
    }
}
