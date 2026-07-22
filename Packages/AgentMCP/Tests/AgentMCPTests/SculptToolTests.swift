import Foundation
import SculptKit
import Testing
import USDCore
@testable import AgentMCP

@Suite struct SculptToolTests {

    /// A spec that exercises every primitive, a library prefab, a group, a
    /// repetition system, and one painted node.
    static func richSpec() -> ObjectSculptSpec {
        let nodes = [
            ComponentNode(name: "Pl", shape: .primitive(.plane), materialID: "red"),
            ComponentNode(name: "Bx", shape: .primitive(.box)),
            ComponentNode(name: "Cy", shape: .primitive(.cylinder),
                          repetition: RepetitionSystem(name: "r", count: 2, step: [1, 0, 0])),
            ComponentNode(name: "Cn", shape: .primitive(.cone)),
            ComponentNode(name: "Sp", shape: .primitive(.sphere)),
            ComponentNode(name: "Lib", shape: .library(entryID: "prefab.crate")),
        ]
        let root = ComponentNode(name: "Sculpt", shape: .group, children: nodes)
        return ObjectSculptSpec(
            name: "Sculpt", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "red", baseColor: [1, 0, 0])])
    }

    static func specArg(_ spec: ObjectSculptSpec) -> JSONValue {
        try! JSONValue.parse(spec.encoded())
    }

    func passingReview() -> JSONValue {
        ["decision": "continue", "score": 0.95,
         "renderPath": "/tmp/r.png", "comparisonSheetPath": "/tmp/c.png"]
    }

    // MARK: - Assess

    @Test func assessClassifiesAndStores() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let out = await callOK(server, "sculpt_assess",
            ["hints": ["wooden barrel"], "width": 512, "height": 512])
        #expect(out["objectClass"].stringValue == "object")
        #expect(out["policy"]["minScore"].doubleValue == 0.7)

        _ = await callError(server, "sculpt_assess", ["hints": ["x"], "width": 0, "height": 10])
    }

    // MARK: - Author + validate

    @Test func authorValidateAndReject() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        // Validate before authoring → error.
        _ = await callError(server, "sculpt_validate_spec")

        let authored = await callOK(server, "sculpt_author_spec",
            ["spec": Self.specArg(Self.richSpec())])
        #expect(authored["componentCount"].doubleValue == 7)
        #expect(authored["currentPass"].stringValue == "blockout")

        // Schema-valid spec passes.
        let valid = await callOK(server, "sculpt_validate_spec", ["strictQuality": false])
        #expect(valid["valid"].boolValue == true)

        // Non-object spec + undecodable spec → errors.
        _ = await callError(server, "sculpt_author_spec", ["spec": "not-an-object"])
        _ = await callError(server, "sculpt_author_spec", ["spec": ["bogus": "shape"]])
    }

    /// A decode failure inside a nested node names the offending key AND its
    /// path, not a cryptic `keyNotFound(CodingKeys(...))` (issue #112).
    @Test func authorDecodeErrorNamesNestedKey() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        // `root` is present but its `shape` is missing → keyNotFound at "root".
        let bad: JSONValue = .object([
            "name": .string("X"), "objectClass": .string("object"),
            "root": .object(["name": .string("Root")]),
        ])
        let message = await callError(server, "sculpt_author_spec", ["spec": bad])
        #expect(message.contains("shape"))
        #expect(message.contains("root"))

        // An unrecognized `shape` form is a data-corrupted error (the ShapeKind
        // decoder) — still reported with its path, not a raw dump.
        let corrupt: JSONValue = .object([
            "name": .string("X"), "objectClass": .string("object"),
            "root": .object(["name": .string("Root"), "shape": .object(["mystery": .bool(true)])]),
        ])
        let corruptMessage = await callError(server, "sculpt_author_spec", ["spec": corrupt])
        #expect(corruptMessage.contains("invalid data"))
        #expect(corruptMessage.contains("shape"))
    }

    /// Re-running `sculpt_build_pass` on blockout must not error with "'X'
    /// already exists" — the create steps are idempotent (issue #111).
    @Test func rebuildBlockoutIsIdempotent() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        let first = await callOK(server, "sculpt_build_pass")
        #expect(first["pass"].stringValue == "blockout")
        // Second run over the already-authored subtree succeeds (no throw), with
        // the same step count — every create resolves to the existing prim.
        let second = await callOK(server, "sculpt_build_pass")
        #expect(second["stepCount"].doubleValue == first["stepCount"].doubleValue)
    }

    @Test func strictQualityGateRejectsShallowSpec() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_assess", ["hints": ["character"], "width": 1024, "height": 1024])
        // Minimal spec: two components, no details/materials → strict gate fails.
        let leaf = ComponentNode(name: "Body", shape: .primitive(.box))
        let root = ComponentNode(name: "Tiny", shape: .group, children: [leaf])
        let spec = ObjectSculptSpec(name: "Tiny", objectClass: .character, root: root)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(spec)])
        let msg = await callError(server, "sculpt_validate_spec", ["strictQuality": true])
        #expect(msg.contains("strict-quality"))
    }

    // MARK: - Full build/review loop

    @Test func buildAndReviewLoop() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])

        // Status before any build.
        let status0 = await callOK(server, "sculpt_status")
        #expect(status0["currentPass"].stringValue == "blockout")

        // Blockout authors geometry AND places each component at its transform
        // (issue #115): 8 prims (group + 5 primitives + 1 repetition copy +
        // library) × (create + setTransform) = 16 steps.
        let blockout = await callOK(server, "sculpt_build_pass")
        #expect(blockout["pass"].stringValue == "blockout")
        #expect(blockout["stepCount"].doubleValue == 16)
        #expect(blockout["reviewOnly"].boolValue == false)
        #expect(session.stage.prim(at: PrimPath("/Sculpt/Cy_r1")!) != nil)

        // continue → structural.
        let adv = await callOK(server, "sculpt_review", passingReview())
        #expect(adv["result"].stringValue == "advanced")
        #expect(adv["currentPass"].stringValue == "structural")

        // Structural places every existing prim.
        let structural = await callOK(server, "sculpt_build_pass")
        #expect(structural["pass"].stringValue == "structural")
        #expect(structural["stepCount"].doubleValue == 8)

        _ = await callOK(server, "sculpt_review", passingReview())   // → formRefinement
        let refine = await callOK(server, "sculpt_build_pass")       // review-only pass
        #expect(refine["reviewOnly"].boolValue == true)

        _ = await callOK(server, "sculpt_review", passingReview())   // → material
        let material = await callOK(server, "sculpt_build_pass")
        #expect(material["stepCount"].doubleValue == 1)              // only Pl is painted

        let status = await callOK(server, "sculpt_status")
        #expect(status["reviewCount"].doubleValue == 3)
        #expect(status["lastScore"].doubleValue == 0.95)
    }

    @Test func reviewDecisionsAndGates() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        // Review/build/status before authoring → errors / uninitialized.
        _ = await callError(server, "sculpt_build_pass")
        _ = await callError(server, "sculpt_review", ["decision": "continue"])
        let uninit = await callOK(server, "sculpt_status")
        #expect(uninit["initialized"].boolValue == false)

        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])

        // Invalid decision string.
        _ = await callError(server, "sculpt_review", ["decision": "nope"])
        // continue without evidence → gate rejects (AdvanceError → invalidParams).
        _ = await callError(server, "sculpt_review", ["decision": "continue"])

        // refineSpec / refineCode stay; requestInput pauses.
        let staying = await callOK(server, "sculpt_review", ["decision": "refineSpec"])
        #expect(staying["result"].stringValue == "staying")
        let staying2 = await callOK(server, "sculpt_review", ["decision": "refineCode"])
        #expect(staying2["result"].stringValue == "staying")
        let waiting = await callOK(server, "sculpt_review", ["decision": "requestInput"])
        #expect(waiting["result"].stringValue == "awaitingInput")
    }

    @Test func continueThroughCompletionAndHalt() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])

        // 7 continues advance blockout→optimization, the 8th completes.
        for _ in 0..<7 { _ = await callOK(server, "sculpt_review", passingReview()) }
        let done = await callOK(server, "sculpt_review", passingReview())
        #expect(done["result"].stringValue == "completed")
        // Once complete, further review is rejected.
        _ = await callError(server, "sculpt_review", passingReview())
    }

    @Test func stopHalts() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        let halted = await callOK(server, "sculpt_review", ["decision": "stop"])
        #expect(halted["result"].stringValue == "halted")
    }

    // MARK: - Step executor edge cases (direct)

    @Test func executeStepEdgeCases() async throws {
        let session = Fixtures.session()

        // Group + mesh + material + transform against real prims succeed.
        let group = try await SculptTools.execute(
            step: .createGroup(name: "G", parentPath: nil), session: session)
        #expect(group == "/G")
        let mesh = try await SculptTools.execute(
            step: .createMesh(name: "M", parentPath: "/G", primitive: .box,
                              width: 1, height: 1, depth: 1, radius: 0.5, segments: 8),
            session: session)
        #expect(mesh == "/G/M")
        let mat = try await SculptTools.execute(
            step: .createMaterial(targetPath: "/G/M",
                                  material: MaterialSpec(id: "m", baseColor: [0.2, 0.2, 0.2])),
            session: session)
        #expect(mat!.contains("Material"))
        let xf = try await SculptTools.execute(
            step: .setTransform(path: "/G/M", translation: [1, 2, 3],
                                rotationEulerDegrees: [0, 0, 0], scale: [1, 1, 1]),
            session: session)
        #expect(xf == "/G/M")

        // Unknown library entry, and transform/material on a missing prim → throw.
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .createLibraryMesh(name: "X", parentPath: nil, entryID: "prefab.ghost"),
                session: session)
        }
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .setTransform(path: "/Nope", translation: [0, 0, 0],
                                    rotationEulerDegrees: [0, 0, 0], scale: [1, 1, 1]),
                session: session)
        }
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .createMaterial(targetPath: "/Nope",
                                      material: MaterialSpec(id: "m", baseColor: [0, 0, 0])),
                session: session)
        }
    }

    // MARK: - Suitability

    @Test func assessSurfacesSuitability() async {
        let server = Fixtures.server(session: Fixtures.session())
        // Viable reference.
        let ok = await callOK(server, "sculpt_assess", ["hints": ["wooden barrel"], "width": 512, "height": 512])
        #expect(ok["suitability"]["verdict"].stringValue == "viable")
        // Too small → rejected verdict (still a successful call, agent decides).
        let tiny = await callOK(server, "sculpt_assess", ["hints": ["barrel"], "width": 10, "height": 10])
        #expect(tiny["suitability"]["verdict"].stringValue == "rejected")
        #expect(tiny["suitability"]["reasons"].arrayValue?.isEmpty == false)
    }

    // MARK: - Action-ready gate + runtime authoring

    /// A spec exposing a runtime handle (collider) so the interaction pass can
    /// author the runtime manifest.
    static func actionableSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box))
        let root = ComponentNode(name: "Root", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Root", objectClass: .object, root: root,
            colliders: [Collider(name: "hull", kind: .box, component: "Body")])
    }

    @Test func interactionGateBlocksWithoutRuntime() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        // Advance blockout → interaction (6 continues).
        for _ in 0..<6 { _ = await callOK(server, "sculpt_review", passingReview()) }
        let status = await callOK(server, "sculpt_status")
        #expect(status["currentPass"].stringValue == "interaction")
        #expect(status["actionReady"].boolValue == false)
        // Building interaction without any runtime handles is rejected.
        let msg = await callError(server, "sculpt_build_pass")
        #expect(msg.contains("action-ready"))
    }

    @Test func interactionPassAuthorsRuntimeManifest() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.actionableSpec())])
        for _ in 0..<6 { _ = await callOK(server, "sculpt_review", passingReview()) }
        let built = await callOK(server, "sculpt_build_pass")
        #expect(built["pass"].stringValue == "interaction")
        #expect(built["stepCount"].doubleValue == 1)
        // The runtime manifest is authored onto the root prim.
        let attr = session.stage.prim(at: PrimPath("/Root")!)?.attribute(named: "sculptRuntime")
        #expect(attr != nil)
    }

    @Test func executeAuthorRuntimeStep() async throws {
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "Rt", parentPath: nil), session: session)
        let path = try await SculptTools.execute(
            step: .authorRuntime(rootPath: "/Rt", manifestJSON: "{\"nodes\":[\"Rt\"]}"), session: session)
        #expect(path == "/Rt")
        #expect(session.stage.prim(at: PrimPath("/Rt")!)?.attribute(named: "sculptRuntime") != nil)
        // A missing root prim throws.
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .authorRuntime(rootPath: "/Ghost", manifestJSON: "{}"), session: session)
        }
    }

    // MARK: - Material depth (texture channels)

    /// A spec whose single painted leaf carries a fully-textured material, so
    /// the material pass authors every extra channel onto the surface shader.
    static func texturedSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), materialID: "pbr")
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            materials: [MaterialSpec(
                id: "pbr", baseColor: [0.5, 0.5, 0.5], roughness: 0.4, metallic: 0.2,
                emissive: [0.1, 0, 0], albedoMap: "albedo.png", normalMap: "normal.png",
                roughnessMap: "rough.png", emissiveMap: "emit.png", normalScale: 0.75)])
    }

    @Test func materialPassAuthorsTextureChannels() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.texturedSpec())])
        _ = await callOK(server, "sculpt_build_pass")                     // blockout
        _ = await callOK(server, "sculpt_review", passingReview())        // → structural
        _ = await callOK(server, "sculpt_build_pass")                     // structural
        _ = await callOK(server, "sculpt_review", passingReview())        // → formRefinement
        _ = await callOK(server, "sculpt_review", passingReview())        // → material
        let material = await callOK(server, "sculpt_build_pass")
        #expect(material["stepCount"].doubleValue == 1)

        // Every extra channel landed on the surface shader.
        let surface = session.stage.prim(at: PrimPath("/Looks/Material/Surface")!)
        #expect(surface?.attribute(named: "inputs:roughness") != nil)
        #expect(surface?.attribute(named: "inputs:metallic") != nil)
        #expect(surface?.attribute(named: "inputs:emissiveColor") != nil)
        #expect(surface?.attribute(named: "inputs:albedoMap") != nil)
        #expect(surface?.attribute(named: "inputs:normalMap") != nil)
        #expect(surface?.attribute(named: "inputs:roughnessMap") != nil)
        #expect(surface?.attribute(named: "inputs:emissiveMap") != nil)
        #expect(surface?.attribute(named: "inputs:normalScale") != nil)
    }

    // MARK: - Surface pass (projected-texture descriptor)

    /// A spec declaring a surface projection so the surface pass authors the
    /// projected-texture descriptor.
    static func surfaceSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box))
        let root = ComponentNode(name: "Obj", shape: .group, children: [body])
        return ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            surfaceProjection: SurfaceProjection(
                targetComponent: "Body",
                camera: CameraPose(position: [0, 0, 5], target: [0, 0, 0])))
    }

    @Test func surfacePassAuthorsProjectedTextureDescriptor() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.surfaceSpec())])
        _ = await callOK(server, "sculpt_build_pass")             // blockout
        // Advance blockout → structural → formRefinement → material → surface.
        for _ in 0..<4 { _ = await callOK(server, "sculpt_review", passingReview()) }
        let status = await callOK(server, "sculpt_status")
        #expect(status["currentPass"].stringValue == "surface")
        let built = await callOK(server, "sculpt_build_pass")
        #expect(built["pass"].stringValue == "surface")
        #expect(built["stepCount"].doubleValue == 1)
        let attr = session.stage.prim(at: PrimPath("/Obj")!)?.attribute(named: "sculptProjectedTexture")
        #expect(attr != nil)
    }

    @Test func executeProjectTextureStep() async throws {
        let session = Fixtures.session()
        _ = try await SculptTools.execute(step: .createGroup(name: "Rt", parentPath: nil), session: session)
        let path = try await SculptTools.execute(
            step: .projectTexture(rootPath: "/Rt", descriptorJSON: "{\"uvSet\":\"st\"}"), session: session)
        #expect(path == "/Rt")
        #expect(session.stage.prim(at: PrimPath("/Rt")!)?.attribute(named: "sculptProjectedTexture") != nil)
        // A missing root prim throws.
        await #expect(throws: (any Error).self) {
            try await SculptTools.execute(
                step: .projectTexture(rootPath: "/Ghost", descriptorJSON: "{}"), session: session)
        }
    }

    // MARK: - Comparison sheet

    @Test func comparisonSheetWritesArtifact() async {
        let work = Fixtures.tempDirectory()
        let server = Fixtures.server(session: Fixtures.session(), configuration: .init(workDirectory: work))

        // Before authoring → error (no orchestrator).
        _ = await callError(server, "sculpt_comparison_sheet",
            ["referencePath": "/tmp/ref.png", "renderPath": "/tmp/out.png"])

        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        let out = await callOK(server, "sculpt_comparison_sheet",
            ["referencePath": "/tmp/ref.png", "renderPath": "/tmp/out.png"])
        #expect(out["pass"].stringValue == "blockout")
        let path = out["comparisonSheetPath"].stringValue ?? ""
        #expect(FileManager.default.fileExists(atPath: path))

        // Missing required paths → error.
        _ = await callError(server, "sculpt_comparison_sheet", ["referencePath": "/tmp/ref.png"])
    }

    // #113: authoring a spec whose components lack `attachment` returns a
    // warning immediately, instead of only failing later at strict validate.
    @Test func authorWarnsOnMissingAttachment() async {
        let server = Fixtures.server(session: Fixtures.session())
        let out = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        let warnings = out["warnings"].arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(warnings.contains { $0.contains("attachment") })

        // A spec whose geometry declares attachments produces no such warning.
        let attached = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, attachment: .root, children: [attached])
        let clean = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        let ok = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(clean)])
        #expect(ok["warnings"].arrayValue?.isEmpty == true)
    }

    // #112: decode failures name the offending key/path instead of dumping
    // `keyNotFound(CodingKeys(...))`.
    @Test func authorGivesFriendlyDecodeError() async {
        let server = Fixtures.server(session: Fixtures.session())
        // Missing required top-level `root`.
        let bad: JSONValue = ["spec": ["name": "X", "objectClass": "object"]]
        let err = await callError(server, "sculpt_author_spec", bad)
        #expect(err.contains("root") || err.contains("missing required key"))
    }

    @Test func decodeHintNamesEachErrorKind() {
        enum K: String, CodingKey { case a }
        let ctxTop = DecodingError.Context(codingPath: [], debugDescription: "d")
        #expect(SculptTools.decodeHint(for: DecodingError.keyNotFound(K.a, ctxTop))
            .contains("top level"))
        let ctxNested = DecodingError.Context(codingPath: [K.a], debugDescription: "d")
        #expect(SculptTools.decodeHint(for: DecodingError.keyNotFound(K.a, ctxNested))
            .contains("under 'a'"))
        #expect(SculptTools.decodeHint(for: DecodingError.typeMismatch(Int.self, ctxNested))
            .contains("wrong type"))
        #expect(SculptTools.decodeHint(for: DecodingError.valueNotFound(Int.self, ctxNested))
            .contains("null"))
        #expect(SculptTools.decodeHint(for: DecodingError.dataCorrupted(ctxNested))
            .contains("malformed"))
        #expect(SculptTools.decodeHint(for: DecodingError.dataCorrupted(ctxTop))
            .contains("malformed"))
        // Array-index path exercises the intValue key branch.
        struct I: CodingKey { var stringValue = "0"; var intValue: Int? = 0
            init() {}; init?(stringValue: String) { nil }; init?(intValue: Int) { self.intValue = intValue } }
        #expect(SculptTools.decodeHint(for: DecodingError.typeMismatch(Int.self,
            .init(codingPath: [I()], debugDescription: "d"))).contains("[0]"))
        // Non-DecodingError falls through to the generic message.
        struct Other: Error {}
        #expect(SculptTools.decodeHint(for: Other()).contains("could not decode spec"))
    }

    // #114: building into a stage that already holds foreign prims warns; a
    // clean stage does not.
    @Test func buildWarnsOnNonEmptyStage() async {
        let dirty = Fixtures.server(session: Fixtures.session())   // has /Root
        _ = await callOK(dirty, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        let built = await callOK(dirty, "sculpt_build_pass")
        #expect(built["warnings"].arrayValue?.contains { $0.stringValue?.contains("not empty") == true } == true)

        let clean = Fixtures.server(session: Fixtures.emptySession())
        _ = await callOK(clean, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        let ok = await callOK(clean, "sculpt_build_pass")
        #expect(ok["warnings"].arrayValue?.isEmpty == true)
    }

    // #111: re-running the same build pass must not error with "already exists";
    // create steps are idempotent, so a refine→rebuild loop can progress.
    @Test func rebuildingBlockoutIsIdempotent() async {
        let server = Fixtures.server(session: Fixtures.emptySession())
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        let first = await callOK(server, "sculpt_build_pass")
        #expect(first["reviewOnly"].boolValue == false)
        // Second call over the same (now-populated) stage succeeds rather than
        // throwing on the existing /Sculpt group.
        let second = await callOK(server, "sculpt_build_pass")
        #expect(second["pass"].stringValue == "blockout")
    }

    @Test func specPersistedToWorkDirectory() async {
        let work = Fixtures.tempDirectory()
        let session = Fixtures.session()
        let server = Fixtures.server(
            session: session,
            configuration: .init(workDirectory: work))
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.richSpec())])
        #expect(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("sculpt-spec.json").path))
    }
}
