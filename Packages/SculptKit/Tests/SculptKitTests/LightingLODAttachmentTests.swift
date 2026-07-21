import Foundation
import Testing
@testable import SculptKit

/// Covers the lighting pass, LOD/optimization pass, attachment-correctness
/// gate, per-feature acceptance, and the image probe.
@Suite struct LightingLODAttachmentTests {

    // MARK: - Fixtures

    /// A minimal grounded spec: a root group with one welded geometry leaf.
    static func groundedSpec() -> ObjectSculptSpec {
        let leaf = ComponentNode(name: "Body", shape: .primitive(.box),
                                 materialID: nil, attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [leaf])
        return ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
    }

    // MARK: - LightSpec

    @Test func lightKindUSDTypeNames() {
        #expect(LightSpec.Kind.distant.usdTypeName == "DistantLight")
        #expect(LightSpec.Kind.sphere.usdTypeName == "SphereLight")
        #expect(LightSpec.Kind.rect.usdTypeName == "RectLight")
        #expect(LightSpec.Kind.dome.usdTypeName == "DomeLight")
        #expect(LightSpec.Kind.allCases.count == 4)
    }

    @Test func lightSpecIdentifiableByName() {
        let light = LightSpec(name: "key", kind: .distant)
        #expect(light.id == "key")
        #expect(light.intensity == 1)
        #expect(light.color == [1, 1, 1])
    }

    // MARK: - Lighting pass planning

    @Test func lightingStepsEmptyWhenNoLights() {
        #expect(BuildPlanner.plan(for: Self.groundedSpec(), pass: .lighting).isEmpty)
    }

    @Test func lightingStepsAuthorLightAndTransform() {
        var spec = Self.groundedSpec()
        spec.lights = [LightSpec(name: "key", kind: .distant, intensity: 5,
                                 color: [1, 0.9, 0.8], translation: [0, 3, 0],
                                 rotationEulerDegrees: [45, 0, 0])]
        let steps = BuildPlanner.plan(for: spec, pass: .lighting)
        #expect(steps.count == 2)
        #expect(steps[0] == .createLight(name: "key", parentPath: "/Obj", kind: .distant,
                                         intensity: 5, color: [1, 0.9, 0.8]))
        #expect(steps[1] == .setTransform(path: "/Obj/key", translation: [0, 3, 0],
                                          rotationEulerDegrees: [45, 0, 0], scale: [1, 1, 1]))
    }

    // MARK: - LOD / optimization pass planning

    @Test func optimizationStepsEmptyWhenNoTiers() {
        #expect(BuildPlanner.plan(for: Self.groundedSpec(), pass: .optimization).isEmpty)
    }

    @Test func optimizationStepsAuthorLODManifest() throws {
        var spec = Self.groundedSpec()
        spec.lodTiers = [LODTier(name: "hi", screenCoverage: 1, decimation: 1),
                         LODTier(name: "lo", screenCoverage: 0.1, decimation: 0.25)]
        let steps = BuildPlanner.plan(for: spec, pass: .optimization)
        #expect(steps.count == 1)
        let expectedJSON = try LODManifest(spec: spec).json()
        #expect(steps[0] == .authorLOD(rootPath: "/Obj", manifestJSON: expectedJSON))
    }

    @Test func formRefinementRemainsReviewOnly() {
        #expect(BuildPlanner.plan(for: Self.groundedSpec(), pass: .formRefinement).isEmpty)
    }

    @Test func lodManifestHasTiers() {
        #expect(LODManifest(tiers: []).hasTiers == false)
        #expect(LODManifest(tiers: [LODTier(name: "a", screenCoverage: 1, decimation: 1)]).hasTiers)
    }

    // MARK: - Light schema validation

    @Test func lightSchemaAcceptsValid() {
        var spec = Self.groundedSpec()
        spec.lights = [LightSpec(name: "key", kind: .sphere, intensity: 2, color: [0.5, 0.5, 0.5])]
        #expect(SpecValidator.validate(spec).isValid)
    }

    @Test func lightSchemaRejectsBadFields() {
        var spec = Self.groundedSpec()
        spec.lights = [
            LightSpec(name: "1bad", kind: .distant),                       // invalid identifier
            LightSpec(name: "dup", kind: .distant),
            LightSpec(name: "dup", kind: .distant),                        // duplicate
            LightSpec(name: "neg", kind: .distant, intensity: -1),         // bad intensity
            LightSpec(name: "nan", kind: .distant, intensity: .nan),       // non-finite intensity
            LightSpec(name: "col", kind: .distant, color: [2, 0, 0]),      // colour out of range
            LightSpec(name: "tv", kind: .distant, translation: [0, 0]),    // translation not [x,y,z]
            LightSpec(name: "tf", kind: .distant, translation: [0, .infinity, 0]), // non-finite translation
            LightSpec(name: "rf", kind: .distant, rotationEulerDegrees: [.nan, 0, 0]), // non-finite rotation
        ]
        let errors = SpecValidator.validate(spec).errors.map(\.message)
        #expect(errors.contains { $0.contains("not a valid USD identifier") })
        #expect(errors.contains { $0.contains("duplicate light name 'dup'") })
        #expect(errors.contains { $0.contains("'neg' intensity") })
        #expect(errors.contains { $0.contains("'nan' intensity") })
        #expect(errors.contains { $0.contains("'col' color") })
        #expect(errors.contains { $0.contains("'tv' translation must be [x, y, z]") })
        #expect(errors.contains { $0.contains("'tf' translation must be finite") })
        #expect(errors.contains { $0.contains("'rf' rotation must be finite") })
    }

    // MARK: - LOD schema validation

    @Test func lodSchemaAcceptsValid() {
        var spec = Self.groundedSpec()
        spec.lodTiers = [LODTier(name: "hi", screenCoverage: 1, decimation: 1)]
        #expect(SpecValidator.validate(spec).isValid)
    }

    @Test func lodSchemaRejectsBadFields() {
        var spec = Self.groundedSpec()
        spec.lodTiers = [
            LODTier(name: "", screenCoverage: 0.5, decimation: 0.5),      // empty name
            LODTier(name: "cov", screenCoverage: 1.5, decimation: 0.5),   // coverage > 1
            LODTier(name: "covn", screenCoverage: .nan, decimation: 0.5), // coverage non-finite
            LODTier(name: "dec", screenCoverage: 0.5, decimation: 0),     // decimation <= 0
            LODTier(name: "dec2", screenCoverage: 0.5, decimation: 1.2),  // decimation > 1
        ]
        let errors = SpecValidator.validate(spec).errors.map(\.message)
        #expect(errors.contains { $0.contains("name must not be empty") })
        #expect(errors.contains { $0.contains("'cov' screenCoverage") })
        #expect(errors.contains { $0.contains("'covn' screenCoverage") })
        #expect(errors.contains { $0.contains("'dec' decimation") })
        #expect(errors.contains { $0.contains("'dec2' decimation") })
    }

    // MARK: - Attachment-correctness gate

    @Test func attachmentGateAcceptsWeldedLeaf() {
        // groundedSpec's Body is welded; root Obj is a group and exempt.
        let result = SpecValidator.validate(Self.groundedSpec(), strictQuality: true)
        #expect(!result.errors.contains { $0.message.contains("floats") })
    }

    @Test func attachmentGateRejectsUnspecified() {
        let leaf = ComponentNode(name: "Body", shape: .primitive(.box)) // no attachment
        let root = ComponentNode(name: "Obj", shape: .group, children: [leaf])
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        let errors = SpecValidator.validate(spec, strictQuality: true).errors.map(\.message)
        #expect(errors.contains { $0.contains("component 'Body' floats") })
    }

    @Test func attachmentGateRejectsFree() {
        let leaf = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .free)
        let root = ComponentNode(name: "Obj", shape: .group, children: [leaf])
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        let errors = SpecValidator.validate(spec, strictQuality: true).errors.map(\.message)
        #expect(errors.contains { $0.contains("component 'Body' is attachment '.free'") })
    }

    @Test func attachmentGateExemptsGeometryRoot() {
        // A geometry root with no attachment must not be flagged (it grounds).
        let root = ComponentNode(name: "Obj", shape: .primitive(.box))
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        let errors = SpecValidator.validate(spec, strictQuality: true).errors.map(\.message)
        #expect(!errors.contains { $0.contains("floats") })
    }

    @Test func attachmentKindRoundTrips() throws {
        #expect(AttachmentKind.allCases.count == 5)
        var spec = Self.groundedSpec()
        spec.root.children[0].attachment = .socket
        let decoded = try ObjectSculptSpec.decoded(from: spec.encoded())
        #expect(decoded.root.children[0].attachment == .socket)
    }

    // MARK: - Per-feature acceptance

    @Test func detailItemAcceptance() {
        #expect(DetailItem(id: "a", description: "", kind: .other).isAccepted)               // no threshold
        #expect(!DetailItem(id: "a", description: "", kind: .other, minScore: 0.8).isAccepted) // no score
        #expect(!DetailItem(id: "a", description: "", kind: .other, score: 0.5, minScore: 0.8).isAccepted)
        #expect(DetailItem(id: "a", description: "", kind: .other, score: 0.9, minScore: 0.8).isAccepted)
    }

    @Test func applyScoresUpdatesKnownItems() {
        var inv = DetailInventory()
        inv.upsert(DetailItem(id: "a", description: "", kind: .other, minScore: 0.8))
        inv.upsert(DetailItem(id: "b", description: "", kind: .other))
        let applied = inv.applyScores(["a": 0.9, "zzz": 0.5])
        #expect(applied == ["a"])
        #expect(inv.items[0].score == 0.9)
        #expect(inv.unaccepted.isEmpty)
    }

    @Test func featureAcceptanceGate() {
        var spec = Self.groundedSpec()
        spec.detailInventory.upsert(DetailItem(id: "hi", description: "", kind: .gloss, minScore: 0.8))
        // No score yet → blocked.
        var result = SpecValidator.featureAcceptance(spec)
        #expect(!result.isValid)
        #expect(result.errors[0].message.contains("feature 'hi' below acceptance"))
        // Record a passing score → accepted.
        spec.detailInventory.applyScores(["hi": 0.85])
        result = SpecValidator.featureAcceptance(spec)
        #expect(result.isValid)
    }

    // MARK: - Image probe

    @Test func probeRejectsTooSmall() {
        let r = ImageProbe.probe(width: 40, height: 512)
        #expect(r.verdict == .unusable)
        #expect(r.recommendedMaxComponents == 0)
        #expect(r.reasons.contains { $0.contains("below the 64px floor") })
    }

    @Test func probeMarginalWhenTight() {
        let r = ImageProbe.probe(width: 128, height: 128)
        #expect(r.verdict == .marginal)
        #expect(r.reasons.contains { $0.contains("tight") })
        #expect(r.recommendedMaxComponents >= 2)
    }

    @Test func probeUsableLargeImage() {
        let r = ImageProbe.probe(width: 1024, height: 1024, hasAlpha: true)
        #expect(r.verdict == .usable)
        #expect(r.megapixels == 1.049)
        #expect(r.aspectRatio == 1)
        #expect(r.recommendedMaxComponents == 27) // Int(1.048576*24)+2 = 25+2
        #expect(r.reasons.contains { $0.contains("alpha channel present") })
    }

    @Test func probeExtremeAspectFlagged() {
        let r = ImageProbe.probe(width: 1200, height: 300, hasAlpha: false)
        #expect(r.verdict == .marginal)               // usable res, extreme aspect demotes
        #expect(r.reasons.contains { $0.contains("aspect") && $0.contains("extreme") })
        #expect(r.reasons.contains { $0.contains("no alpha channel") })
    }

    @Test func probeComponentCeilingClamped() {
        let r = ImageProbe.probe(width: 4000, height: 4000) // 16MP → 24*16+2 clamps to 64
        #expect(r.recommendedMaxComponents == 64)
    }
}
