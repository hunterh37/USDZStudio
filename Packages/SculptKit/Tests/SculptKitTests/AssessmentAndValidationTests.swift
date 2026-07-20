import Testing
@testable import SculptKit

@Suite struct AssessmentTests {

    @Test func classifiesObject() {
        let a = PreSpecAssessment.assess(hints: ["wooden barrel"], width: 512, height: 512)
        #expect(a.objectClass == .object)
        #expect(a.complexity == 1)
        #expect(a.policy.requireMaterials == false)
        #expect(a.policy.minComponents == 2)
        #expect(a.policy.minScore == 0.7)
    }

    @Test func classifiesCharacter() {
        let a = PreSpecAssessment.assess(hints: ["character"], width: 256, height: 256)
        #expect(a.objectClass == .character)
        #expect(a.complexity == 2)          // base 1 + character bump
        #expect(a.policy.minScore == 0.8)
        #expect(a.policy.requireMaterials == true)
    }

    @Test func classifiesHybridWithManyHints() {
        let a = PreSpecAssessment.assess(
            hints: ["robot", "glossy", "bevels", "wear"], width: 256, height: 256)
        #expect(a.objectClass == .hybrid)   // character keyword + >=4 hints
        #expect(a.complexity == 4)          // 1 + 4/2=3, +1 character
    }

    @Test func largeImageBumpsComplexity() {
        let small = PreSpecAssessment.assess(hints: ["barrel"], width: 100, height: 100)
        let large = PreSpecAssessment.assess(hints: ["barrel"], width: 1024, height: 1024)
        #expect(large.complexity == small.complexity + 1)
    }

    @Test func emptyHintsNoted() {
        let a = PreSpecAssessment.assess(hints: [], width: 64, height: 64)
        #expect(a.notes.contains { $0.contains("no hints") })
        #expect(a.complexity == 1)
    }

    @Test func complexityCapsAtFive() {
        let a = PreSpecAssessment.assess(
            hints: ["creature", "a", "b", "c", "d", "e", "f", "g", "h", "i"],
            width: 2048, height: 2048)
        #expect(a.complexity == 5)
    }
}

@Suite struct SpecValidatorTests {

    func validSpec() -> ObjectSculptSpec {
        let leaf = ComponentNode(name: "Body", shape: .primitive(.cylinder), materialID: "wood")
        let root = ComponentNode(name: "Barrel", shape: .group, children: [leaf])
        return ObjectSculptSpec(
            name: "Barrel", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "wood", baseColor: [0.4, 0.2, 0.1])])
    }

    @Test func acceptsValidSpec() {
        let result = SpecValidator.validate(validSpec())
        #expect(result.isValid)
        #expect(result.errors.isEmpty)
    }

    @Test func rejectsEmptyName() {
        var spec = validSpec()
        spec.name = ""
        let result = SpecValidator.validate(spec)
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.message.contains("name") })
    }

    @Test func rejectsDuplicateMaterialIDs() {
        var spec = validSpec()
        spec.materials.append(MaterialSpec(id: "wood", baseColor: [0, 0, 0]))
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("duplicate material") })
    }

    @Test func rejectsBadColors() {
        var spec = validSpec()
        spec.materials[0].baseColor = [0.5, 0.5]                    // wrong count
        #expect(!SpecValidator.validate(spec).isValid)
        spec.materials[0].baseColor = [2, 0, 0]                     // out of range
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("0...1") })
        spec.materials[0].baseColor = [0.4, 0.2, 0.1]
        spec.materials[0].emissive = [5, 0, 0]                      // bad emissive
        #expect(!SpecValidator.validate(spec).isValid)
    }

    @Test func rejectsBadRoughnessMetallic() {
        var spec = validSpec()
        spec.materials[0].roughness = 2
        spec.materials[0].metallic = -1
        let errs = SpecValidator.validate(spec).errors.map(\.message)
        #expect(errs.contains { $0.contains("roughness") })
        #expect(errs.contains { $0.contains("metallic") })
    }

    @Test func rejectsBadNodes() {
        var spec = validSpec()
        spec.root.children[0].name = "1bad"                        // invalid identifier
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("valid USD identifier") })

        spec = validSpec()
        spec.root.children[0].scale = [1, 0, 1]                    // zero scale
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("zero component") })

        spec = validSpec()
        spec.root.children[0].translation = [0, 0]                 // bad vec
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("translation") })

        spec = validSpec()
        spec.root.children[0].materialID = "ghost"                 // unknown material
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("unknown material") })

        spec = validSpec()
        spec.root.children[0].width = 0                            // bad dims
        spec.root.children[0].segments = 2                         // bad segments
        let errs = SpecValidator.validate(spec).errors.map(\.message)
        #expect(errs.contains { $0.contains("dimensions") })
        #expect(errs.contains { $0.contains("segments") })
    }

    @Test func rejectsDuplicateNames() {
        let a = ComponentNode(name: "Dup", shape: .primitive(.box))
        let b = ComponentNode(name: "Dup", shape: .primitive(.box))
        let root = ComponentNode(name: "Root", shape: .group, children: [a, b])
        let spec = ObjectSculptSpec(name: "X", objectClass: .object, root: root)
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("duplicate component") })
    }

    @Test func validatesLibraryEntries() {
        var spec = validSpec()
        spec.root.children[0].shape = .library(entryID: "prefab.tree")   // real entry
        #expect(SpecValidator.validate(spec).isValid)
        spec.root.children[0].shape = .library(entryID: "prefab.nonexistent")
        #expect(SpecValidator.validate(spec).errors.contains { $0.message.contains("library entry") })
    }

    @Test func validatesRepetition() {
        var spec = validSpec()
        spec.root.children[0].repetition = RepetitionSystem(name: "r", count: 0, step: [1, 0])
        let errs = SpecValidator.validate(spec).errors.map(\.message)
        #expect(errs.contains { $0.contains("repetition count") })
        #expect(errs.contains { $0.contains("repetition step") })
    }

    // MARK: - Strict-quality gate

    @Test func strictQualityWithoutAssessmentOnlyChecksMapping() {
        var spec = validSpec()
        spec.detailInventory.upsert(DetailItem(id: "d", description: "grain", kind: .linework))
        let result = SpecValidator.validate(spec, strictQuality: true)
        #expect(result.errors.contains { $0.message.contains("unmapped") })
        #expect(result.warnings.contains { $0.message.contains("no assessment") })
    }

    @Test func strictQualityEnforcesPolicy() {
        let assessment = PreSpecAssessment.assess(hints: ["character"], width: 1024, height: 1024)
        // complexity 3 → minDetailItems 3, minComponents 3, requireMaterials true.
        let sparse = validSpec()   // 2 components, 0 details
        let result = SpecValidator.validate(sparse, assessment: assessment, strictQuality: true)
        let msgs = result.errors.map(\.message)
        #expect(msgs.contains { $0.contains("detail items <") })
        #expect(msgs.contains { $0.contains("components <") })
    }

    @Test func strictQualityRequiresMaterialsAndCoverage() {
        let assessment = PreSpecAssessment(
            objectClass: .object, complexity: 1,
            policy: FeatureAcceptancePolicy(minScore: 0.7, minDetailItems: 0,
                                            minComponents: 1, requireMaterials: true))
        // No materials at all.
        let bare = ComponentNode(name: "Body", shape: .primitive(.box))
        let noMat = ObjectSculptSpec(name: "X", objectClass: .object, root: bare)
        #expect(SpecValidator.validate(noMat, assessment: assessment, strictQuality: true)
            .errors.contains { $0.message.contains("no materials") })

        // Materials exist but a geometry leaf is unpainted.
        var spec = validSpec()
        spec.root.children[0].materialID = nil
        #expect(SpecValidator.validate(spec, assessment: assessment, strictQuality: true)
            .errors.contains { $0.message.contains("without a material") })
    }

    @Test func strictQualityPassesWhenComplete() {
        let assessment = PreSpecAssessment(
            objectClass: .object, complexity: 1,
            policy: FeatureAcceptancePolicy(minScore: 0.7, minDetailItems: 1,
                                            minComponents: 2, requireMaterials: true))
        var spec = validSpec()
        spec.detailInventory.upsert(DetailItem(id: "d", description: "grain", kind: .linework, mappedTo: "wood"))
        let result = SpecValidator.validate(spec, assessment: assessment, strictQuality: true)
        #expect(result.isValid)
    }

    // MARK: - PrimName

    @Test func primNameValidation() {
        #expect(PrimName.isValid("Body_1"))
        #expect(PrimName.isValid("_x"))
        #expect(!PrimName.isValid(""))
        #expect(!PrimName.isValid("1bad"))
        #expect(!PrimName.isValid("has space"))
    }
}
