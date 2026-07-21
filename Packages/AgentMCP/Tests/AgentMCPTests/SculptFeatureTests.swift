import Foundation
import SculptKit
import Testing
import USDCore
@testable import AgentMCP

/// Covers the lighting/optimization authoring passes, the probe tool, and the
/// per-feature acceptance gate added on top of the staged-sculpt pipeline.
@Suite struct SculptFeatureTests {

    static func specArg(_ spec: ObjectSculptSpec) -> JSONValue {
        try! JSONValue.parse(spec.encoded())
    }

    func passingReview() -> JSONValue {
        ["decision": "continue", "score": 0.95,
         "renderPath": "/tmp/r.png", "comparisonSheetPath": "/tmp/c.png"]
    }

    /// A grounded spec carrying one light and two LOD tiers.
    static func litSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            lights: [LightSpec(name: "key", kind: .distant, intensity: 4,
                               color: [1, 0.95, 0.9], translation: [0, 4, 2],
                               rotationEulerDegrees: [45, 0, 0])],
            lodTiers: [LODTier(name: "hi", screenCoverage: 1, decimation: 1),
                       LODTier(name: "lo", screenCoverage: 0.2, decimation: 0.3)])
    }

    // MARK: - Probe

    @Test func probeReportsFitness() async {
        let server = Fixtures.server(session: Fixtures.session())
        let ok = await callOK(server, "sculpt_probe", ["width": 1024, "height": 1024, "hasAlpha": true])
        #expect(ok["verdict"].stringValue == "usable")
        #expect(ok["recommendedMaxComponents"].doubleValue == 27)
        #expect(ok["reasons"].arrayValue?.isEmpty == false)

        let tiny = await callOK(server, "sculpt_probe", ["width": 40, "height": 512])
        #expect(tiny["verdict"].stringValue == "unusable")

        _ = await callError(server, "sculpt_probe", ["width": 0, "height": 10])
    }

    // MARK: - Lighting pass authoring

    @Test func lightingPassAuthorsRealLight() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.litSpec())])
        _ = await callOK(server, "sculpt_build_pass")                 // blockout
        // Advance blockout → structural → formRefinement → material → surface → lighting.
        for _ in 0..<5 { _ = await callOK(server, "sculpt_review", passingReview()) }
        let status = await callOK(server, "sculpt_status")
        #expect(status["currentPass"].stringValue == "lighting")
        #expect(status["lightCount"].doubleValue == 1)

        let built = await callOK(server, "sculpt_build_pass")
        #expect(built["pass"].stringValue == "lighting")
        #expect(built["stepCount"].doubleValue == 2)                  // createLight + setTransform
        let light = session.stage.prim(at: PrimPath("/Obj/key")!)
        #expect(light?.typeName == "DistantLight")
        #expect(light?.attribute(named: "inputs:intensity") != nil)
        #expect(light?.attribute(named: "inputs:color") != nil)
    }

    // MARK: - Optimization pass authoring

    @Test func optimizationPassAuthorsLODManifest() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.litSpec())])
        _ = await callOK(server, "sculpt_build_pass")                 // blockout (creates /Obj)
        // Advance blockout → optimization (7 continues).
        for _ in 0..<7 { _ = await callOK(server, "sculpt_review", passingReview()) }
        let status = await callOK(server, "sculpt_status")
        #expect(status["currentPass"].stringValue == "optimization")
        #expect(status["lodTierCount"].doubleValue == 2)

        let built = await callOK(server, "sculpt_build_pass")
        #expect(built["pass"].stringValue == "optimization")
        #expect(built["stepCount"].doubleValue == 1)
        #expect(session.stage.prim(at: PrimPath("/Obj")!)?.attribute(named: "sculptLOD") != nil)
    }

    // MARK: - Feature-acceptance gate

    /// A spec whose lone detail item declares a per-feature threshold.
    static func featureGatedSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        var spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        spec.detailInventory.upsert(
            DetailItem(id: "gloss", description: "wet gloss", kind: .gloss, mappedTo: "Body", minScore: 0.8))
        return spec
    }

    @Test func completionGateEnforcesFeatureScores() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.featureGatedSpec())])

        // Advance blockout → optimization (7 continues; feature gate is inert
        // until the final pass).
        for _ in 0..<7 { _ = await callOK(server, "sculpt_review", passingReview()) }
        let status = await callOK(server, "sculpt_status")
        #expect(status["featuresAccepted"].boolValue == false)
        #expect(status["unacceptedFeatures"].arrayValue?.count == 1)

        // Final continue without a passing feature score → rejected.
        let msg = await callError(server, "sculpt_review", passingReview())
        #expect(msg.contains("feature 'gloss' below acceptance"))

        // Supplying a passing feature score clears the gate → completed.
        var review = passingReview()
        review = ["decision": "continue", "score": 0.95,
                  "renderPath": "/tmp/r.png", "comparisonSheetPath": "/tmp/c.png",
                  "featureScores": ["gloss": 0.9]]
        let done = await callOK(server, "sculpt_review", review)
        #expect(done["result"].stringValue == "completed")
    }

    // MARK: - Executor edge cases

    @Test func executeCreateLightAndLODSteps() async throws {
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "Obj", parentPath: nil), session: session)
        let light = try await SculptTools.execute(
            step: .createLight(name: "key", parentPath: "/Obj", kind: .sphere,
                               intensity: 3, color: [1, 1, 1]), session: session)
        #expect(light == "/Obj/key")
        #expect(session.stage.prim(at: PrimPath("/Obj/key")!)?.typeName == "SphereLight")

        let lod = try await SculptTools.execute(
            step: .authorLOD(rootPath: "/Obj", manifestJSON: "{\"tiers\":[]}"), session: session)
        #expect(lod == "/Obj")
        #expect(session.stage.prim(at: PrimPath("/Obj")!)?.attribute(named: "sculptLOD") != nil)

        // Authoring LOD onto a missing root throws.
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .authorLOD(rootPath: "/Ghost", manifestJSON: "{}"), session: session)
        }
    }
}
