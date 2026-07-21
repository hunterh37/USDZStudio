import Testing
@testable import SculptKit

@Suite struct PassOrchestratorTests {

    func passingReview(_ pass: SculptPass, score: Double = 0.9) -> PassReview {
        PassReview(pass: pass, decision: .continue, score: score,
                   renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png")
    }

    @Test func continueAdvancesThroughAllPasses() throws {
        var orch = PassOrchestrator()
        #expect(orch.current == .blockout)
        #expect(orch.isActive)
        for pass in SculptPass.allCases.dropLast() {
            let result = try orch.advance(after: passingReview(pass), threshold: 0.8)
            #expect(result == .advanced(to: pass.next!))
        }
        // Final pass completes.
        let done = try orch.advance(after: passingReview(.optimization), threshold: 0.8)
        #expect(done == .completed)
        #expect(orch.isComplete)
        #expect(!orch.isActive)
    }

    @Test func continueRequiresFullEvidence() {
        // The evidence bundle (render + comparison sheet + score) is required to
        // continue out of *every* pass, including the fidelity-exempt blockout.
        var orch = PassOrchestrator()
        #expect(throws: AdvanceError.continueRequiresRender) {
            try orch.advance(after: PassReview(pass: .blockout, decision: .continue), threshold: 0.8)
        }
        #expect(throws: AdvanceError.continueRequiresComparisonSheet) {
            try orch.advance(after: PassReview(pass: .blockout, decision: .continue, renderPath: "/r.png"), threshold: 0.8)
        }
        #expect(throws: AdvanceError.continueRequiresScore) {
            try orch.advance(after: PassReview(pass: .blockout, decision: .continue,
                                               renderPath: "/r.png", comparisonSheetPath: "/c.png"), threshold: 0.8)
        }
        // None of the failed attempts advanced the pass.
        #expect(orch.current == .blockout)
    }

    /// Advance an orchestrator to `target` by continuing through each prior
    /// pass with an evidence bundle that clears both gates (score 0.9, ample
    /// similarity), so a test can start at the pass it actually wants to probe.
    func orchestrator(at target: SculptPass, threshold: Double = 0.8,
                      similarityFloor: Double = 0.55) throws -> PassOrchestrator {
        var orch = PassOrchestrator()
        while orch.current != target {
            let r = PassReview(pass: orch.current, decision: .continue, score: 0.9,
                               renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png",
                               measuredSimilarity: 0.9)
            _ = try orch.advance(after: r, threshold: threshold, similarityFloor: similarityFloor)
        }
        return orch
    }

    @Test func blockoutExemptFromBothGates() throws {
        // blockout authors geometry at the origin (placement is structural's
        // job), so it is exempt from the score threshold and the similarity
        // floor: a low subjective score and a missing measured similarity still
        // advance, as long as the evidence bundle is present.
        var orch = PassOrchestrator()
        #expect(!SculptPass.blockout.enforcesScoreGate)
        #expect(!SculptPass.blockout.enforcesSimilarityFloor)
        let result = try orch.advance(
            after: passingReview(.blockout, score: 0.2), threshold: 0.8, similarityFloor: 0.55)
        #expect(result == .advanced(to: .structural))
        #expect(orch.current == .structural)
    }

    @Test func scoreGateEnforcedFromStructuralButFloorDeferred() throws {
        // structural is placed but untextured: the subjective score gate bites,
        // yet the colour-dependent similarity floor is deferred to `material`.
        var orch = try orchestrator(at: .structural)
        #expect(SculptPass.structural.enforcesScoreGate)
        #expect(!SculptPass.structural.enforcesSimilarityFloor)

        // Score threshold bites at structural.
        #expect(throws: AdvanceError.scoreBelowThreshold(score: 0.5, threshold: 0.8)) {
            try orch.advance(after: passingReview(.structural, score: 0.5),
                             threshold: 0.8, similarityFloor: 0.55)
        }
        // A low measured similarity does NOT block a geometry pass (floor deferred)
        // — a passing score with no measured similarity still advances.
        let result = try orch.advance(after: passingReview(.structural, score: 0.9),
                                      threshold: 0.8, similarityFloor: 0.55)
        #expect(result == .advanced(to: .formRefinement))
    }

    @Test func similarityFloorEnforcedFromMaterial() throws {
        // material is the first textured pass — the deterministic floor bites here.
        var orch = try orchestrator(at: .material)
        #expect(SculptPass.material.enforcesSimilarityFloor)

        // Floor requires a measured similarity.
        #expect(throws: AdvanceError.continueRequiresMeasuredSimilarity) {
            try orch.advance(after: passingReview(.material, score: 0.9),
                             threshold: 0.8, similarityFloor: 0.55)
        }
        // Floor rejects a low measured similarity.
        let lowSim = PassReview(pass: .material, decision: .continue, score: 0.9,
                                renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png",
                                measuredSimilarity: 0.3)
        #expect(throws: AdvanceError.similarityBelowFloor(measured: 0.3, floor: 0.55)) {
            try orch.advance(after: lowSim, threshold: 0.8, similarityFloor: 0.55)
        }
        #expect(orch.current == .material)

        // A sufficient render clears both gates.
        let ok = PassReview(pass: .material, decision: .continue, score: 0.9,
                            renderPath: "/tmp/r.png", comparisonSheetPath: "/tmp/c.png",
                            measuredSimilarity: 0.6)
        let result = try orch.advance(after: ok, threshold: 0.8, similarityFloor: 0.55)
        #expect(result == .advanced(to: .surface))
    }

    @Test func gateProperties() {
        // Score gate: exempt only for blockout.
        #expect(!SculptPass.blockout.enforcesScoreGate)
        for pass in SculptPass.allCases where pass != .blockout {
            #expect(pass.enforcesScoreGate)
        }
        // Similarity floor: only the textured passes (material onward).
        let textured: Set<SculptPass> = [.material, .surface, .lighting, .interaction, .optimization]
        for pass in SculptPass.allCases {
            #expect(pass.enforcesSimilarityFloor == textured.contains(pass))
        }
    }

    @Test func refineStaysOnCurrentPass() throws {
        var orch = PassOrchestrator()
        let spec = try orch.advance(after: PassReview(pass: .blockout, decision: .refineSpec), threshold: 0.8)
        #expect(spec == .staying(.blockout))
        let code = try orch.advance(after: PassReview(pass: .blockout, decision: .refineCode), threshold: 0.8)
        #expect(code == .staying(.blockout))
        #expect(orch.current == .blockout)
    }

    @Test func requestInputPausesStopHalts() throws {
        var orch = PassOrchestrator()
        let paused = try orch.advance(after: PassReview(pass: .blockout, decision: .requestInput), threshold: 0.8)
        #expect(paused == .awaitingInput(.blockout))
        #expect(orch.isActive)     // paused, not halted

        let halted = try orch.advance(after: PassReview(pass: .blockout, decision: .stop), threshold: 0.8)
        #expect(halted == .halted(.blockout))
        #expect(orch.isHalted)
        #expect(!orch.isActive)
    }

    @Test func cannotAdvanceOnceInactive() throws {
        var orch = PassOrchestrator()
        _ = try orch.advance(after: PassReview(pass: .blockout, decision: .stop), threshold: 0.8)
        #expect(throws: AdvanceError.notContinuablePass(.blockout)) {
            try orch.advance(after: passingReview(.blockout), threshold: 0.8)
        }
    }

    @Test func canStartAtAribtraryPass() {
        let orch = PassOrchestrator(startingAt: .material)
        #expect(orch.current == .material)
    }

    @Test func advanceErrorDescriptions() {
        let cases: [AdvanceError] = [
            .notContinuablePass(.blockout), .continueRequiresRender,
            .continueRequiresComparisonSheet, .continueRequiresScore,
            .scoreBelowThreshold(score: 0.1, threshold: 0.8),
        ]
        for c in cases { #expect(!c.description.isEmpty) }
    }
}

@Suite struct BuildPlannerTests {

    static func spec() -> ObjectSculptSpec {
        let mesh = ComponentNode(
            name: "Body", shape: .primitive(.cylinder),
            translation: [0, 1, 0], materialID: "wood",
            repetition: RepetitionSystem(name: "hoop", count: 3, step: [0, 0.5, 0]))
        let prefab = ComponentNode(name: "Cap", shape: .library(entryID: "prefab.rock"))
        let root = ComponentNode(name: "Barrel", shape: .group, children: [mesh, prefab])
        return ObjectSculptSpec(
            name: "Barrel", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "wood", baseColor: [0.4, 0.2, 0.1])])
    }

    @Test func blockoutEmitsGeometry() {
        let steps = BuildPlanner.plan(for: Self.spec(), pass: .blockout)
        // group Barrel + Body + 2 repetition copies + library Cap = 5.
        #expect(steps.count == 5)
        #expect(steps[0] == .createGroup(name: "Barrel", parentPath: nil))
        if case .createMesh(let name, let parent, let prim, _, _, _, _, _) = steps[1] {
            #expect(name == "Body")
            #expect(parent == "/Barrel")
            #expect(prim == .cylinder)
        } else { Issue.record("expected createMesh") }
        // Repetition copies are real prims in the blockout.
        if case .createMesh(let name, _, _, _, _, _, _, _) = steps[2] {
            #expect(name == "Body_hoop1")
        } else { Issue.record("expected copy mesh") }
        #expect(steps[4] == .createLibraryMesh(name: "Cap", parentPath: "/Barrel", entryID: "prefab.rock"))
    }

    @Test func blockoutCopiesRespectShapeKind() {
        var spec = Self.spec()
        // A repeated library prefab and a repeated group both copy correctly.
        spec.root.children[1] = ComponentNode(
            name: "Leg", shape: .library(entryID: "prefab.rock"),
            repetition: RepetitionSystem(name: "n", count: 2, step: [1, 0, 0]))
        let steps = BuildPlanner.plan(for: spec, pass: .blockout)
        #expect(steps.contains(.createLibraryMesh(name: "Leg_n1", parentPath: "/Barrel", entryID: "prefab.rock")))
    }

    @Test func structuralPlacesAndExpandsRepetition() {
        let steps = BuildPlanner.plan(for: Self.spec(), pass: .structural)
        // Barrel + Body + 2 repetition copies + Cap = 5 transforms.
        #expect(steps.count == 5)
        let repeated = steps.compactMap { step -> String? in
            if case .setTransform(let path, let t, _, _) = step, path.contains("_hoop") {
                #expect(t[1] > 1)   // offset above the base translation y=1
                return path
            }
            return nil
        }
        #expect(repeated == ["/Barrel/Body_hoop1", "/Barrel/Body_hoop2"])
    }

    @Test func repetitionSkippedWhenTrivial() {
        var spec = Self.spec()
        spec.root.children[0].repetition = RepetitionSystem(name: "x", count: 1, step: [1, 0, 0])
        let single = BuildPlanner.plan(for: spec, pass: .structural)
        #expect(single.count == 3)   // no expansion

        spec.root.children[0].repetition = RepetitionSystem(name: "x", count: 3, step: [1, 0])  // bad step
        let badStep = BuildPlanner.plan(for: spec, pass: .structural)
        #expect(badStep.count == 3)
    }

    @Test func materialPassBindsOnlyPaintedNodes() {
        let steps = BuildPlanner.plan(for: Self.spec(), pass: .material)
        #expect(steps.count == 1)
        #expect(steps[0] == .createMaterial(
            targetPath: "/Barrel/Body",
            material: MaterialSpec(id: "wood", baseColor: [0.4, 0.2, 0.1])))
    }

    @Test func materialPassSkipsDanglingMaterialRef() {
        var spec = Self.spec()
        spec.materials = []   // Body still references "wood" but it's gone
        #expect(BuildPlanner.plan(for: spec, pass: .material).isEmpty)
    }

    @Test func reviewOnlyPassesEmitNothing() {
        for pass: SculptPass in [.formRefinement, .surface, .lighting, .interaction, .optimization] {
            #expect(BuildPlanner.plan(for: Self.spec(), pass: pass).isEmpty)
        }
    }

    @Test func surfacePassAuthorsProjectionWhenTargeted() {
        var spec = Self.spec()
        spec.surfaceProjection = SurfaceProjection(
            targetComponent: "Body",
            camera: CameraPose(position: [0, 0, 5], target: [0, 0, 0]))
        let steps = BuildPlanner.plan(for: spec, pass: .surface)
        #expect(steps.count == 1)
        if case .projectTexture(let rootPath, let json) = steps[0] {
            #expect(rootPath == "/Barrel")
            #expect(json.contains("Body"))
        } else { Issue.record("expected projectTexture step") }
    }

    @Test func surfacePassEmptyWhenTargetMissing() {
        var spec = Self.spec()
        // Projection targeting an unknown component → no step (review-only).
        spec.surfaceProjection = SurfaceProjection(
            targetComponent: "Ghost",
            camera: CameraPose(position: [0, 0, 5], target: [0, 0, 0]))
        #expect(BuildPlanner.plan(for: spec, pass: .surface).isEmpty)
    }

    @Test func pathHelper() {
        #expect(BuildPlanner.path(for: "A", under: nil) == "/A")
        #expect(BuildPlanner.path(for: "B", under: "/A") == "/A/B")
    }
}
