import Foundation
import EditingKit
import MeshKit
import SculptKit
import USDCore

/// Cross-call state for the staged-sculpt pipeline: the pre-spec assessment,
/// the authored spec, and the locked-pass orchestrator. Requests are processed
/// serially by the transport loop, but this is an `actor` so the async tool
/// handlers can share it safely.
public actor SculptStore {
    public private(set) var assessment: PreSpecAssessment?
    public private(set) var spec: ObjectSculptSpec?
    public private(set) var orchestrator: PassOrchestrator?

    public init() {}

    func setAssessment(_ a: PreSpecAssessment) { assessment = a }

    func setSpec(_ s: ObjectSculptSpec) {
        spec = s
        orchestrator = PassOrchestrator()
    }

    /// Build a review for the current pass, record it, and advance the
    /// orchestrator. Optionally records per-feature review scores first, and —
    /// when this `continue` would complete the pipeline — enforces the
    /// feature-acceptance gate. Returns the advance result, or throws if no
    /// spec exists yet or a gate rejects the decision.
    func review(
        decision: PassDecision, score: Double?, renderPath: String?,
        comparisonSheetPath: String?, note: String?, threshold: Double,
        featureScores: [String: Double] = [:]
    ) throws -> AdvanceResult {
        guard spec != nil, orchestrator != nil else {
            throw ToolError.failed("no spec authored yet — call sculpt_author_spec first")
        }
        if !featureScores.isEmpty {
            spec!.detailInventory.applyScores(featureScores)
        }
        // Feature-acceptance completion gate: a `continue` out of the final
        // pass must clear every declared per-feature threshold.
        if decision == .continue, orchestrator!.current.next == nil {
            let acceptance = SpecValidator.featureAcceptance(spec!)
            if !acceptance.isValid {
                throw ToolError.rejectedByValidation(acceptance.errors.map(\.message))
            }
        }
        let review = PassReview(
            pass: orchestrator!.current, decision: decision, score: score,
            renderPath: renderPath, comparisonSheetPath: comparisonSheetPath, note: note)
        spec!.reviewHistory.append(review)
        do {
            return try orchestrator!.advance(after: review, threshold: threshold)
        } catch let error as AdvanceError {
            throw ToolError.invalidParams("\(error)")
        }
    }
}

/// §3.7 Sculpt tools — an img2threejs-style staged-sculpt pipeline that builds
/// a native USD scene: assess → author spec → strict-quality validate →
/// [per locked pass: build → render → score → review] (specs/sculpt-pipeline.md).
/// The mechanical work lives here and in `SculptKit`; the agent spends its
/// tokens only on the visual pass/fail judgment fed to `sculpt_review`.
public enum SculptTools {

    public static func register(
        on server: MCPServer, session: EditSession,
        store: SculptStore, workDirectory: URL
    ) {
        registerProbe(on: server)
        registerAssess(on: server, store: store)
        registerAuthor(on: server, store: store, workDirectory: workDirectory)
        registerValidate(on: server, store: store)
        registerBuild(on: server, session: session, store: store)
        registerReview(on: server, store: store)
        registerStatus(on: server, store: store)
        registerComparisonSheet(on: server, store: store, workDirectory: workDirectory)
    }

    // MARK: - Probe

    private static func registerProbe(on server: MCPServer) {
        server.register(MCPTool(
            name: "sculpt_probe", group: .sculpt,
            description: "Technical fitness probe of a reference image (img2threejs's probe_image intake). Vets pixel dimensions — and optional alpha — before assessment: returns a usable/marginal/unusable verdict, megapixels, aspect ratio, a recommended component ceiling, and the reasons. Decode-free: supply width/height (and hasAlpha if known).",
            inputSchema: Schema.object([
                "width": Schema.integer("reference image width in pixels"),
                "height": Schema.integer("reference image height in pixels"),
                "hasAlpha": Schema.boolean("whether the source carries a transparency channel (optional)"),
            ], required: ["width", "height"])
        ) { args in
            let width = args["width"].intValue ?? 0
            let height = args["height"].intValue ?? 0
            guard width > 0, height > 0 else {
                throw ToolError.invalidParams("'width' and 'height' must be positive")
            }
            let report = ImageProbe.probe(width: width, height: height, hasAlpha: args["hasAlpha"].boolValue)
            return probeReportJSON(report)
        })
    }

    // MARK: - Assess

    private static func registerAssess(on server: MCPServer, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_assess", group: .sculpt,
            description: "Pre-spec assessment of a reference image: classify (character/object/hybrid), score complexity, and set the acceptance policy (thresholds the strict-quality gate and review loop enforce). Deterministic from descriptive hints + image dimensions.",
            inputSchema: Schema.object([
                "hints": Schema.array(of: Schema.string("descriptive tag"), "descriptive tags, e.g. 'wooden barrel', 'rusty', 'glossy'"),
                "width": Schema.integer("reference image width in pixels"),
                "height": Schema.integer("reference image height in pixels"),
            ], required: ["hints", "width", "height"])
        ) { args in
            let hints = args["hints"].stringArrayValue ?? []
            let width = args["width"].intValue ?? 0
            let height = args["height"].intValue ?? 0
            guard width > 0, height > 0 else {
                throw ToolError.invalidParams("'width' and 'height' must be positive")
            }
            let assessment = PreSpecAssessment.assess(hints: hints, width: width, height: height)
            await store.setAssessment(assessment)
            return assessmentJSON(assessment)
        })
    }

    // MARK: - Author spec

    private static func registerAuthor(on server: MCPServer, store: SculptStore, workDirectory: URL) {
        server.register(MCPTool(
            name: "sculpt_author_spec", group: .sculpt,
            description: "Author (or replace) the ObjectSculptSpec: the component tree, materials, sockets, and detail inventory. Pass the full spec as JSON (SculptKit.ObjectSculptSpec shape). Resets the pass orchestrator to blockout and persists the spec to the work directory.",
            inputSchema: Schema.object([
                "spec": .object(["type": "object", "description": "the full ObjectSculptSpec JSON"]),
            ], required: ["spec"])
        ) { args in
            guard case .object = args["spec"] else {
                throw ToolError.invalidParams("'spec' must be an object")
            }
            let spec: ObjectSculptSpec
            do {
                let data = Data(args["spec"].serializedString.utf8)
                spec = try ObjectSculptSpec.decoded(from: data)
            } catch {
                throw ToolError.invalidParams("could not decode spec: \(error)")
            }
            await store.setSpec(spec)
            persist(spec, to: workDirectory)
            return .object([
                "name": .string(spec.name),
                "componentCount": .number(Double(spec.componentCount)),
                "materialCount": .number(Double(spec.materials.count)),
                "detailItems": .number(Double(spec.detailInventory.items.count)),
                "currentPass": .string(SculptPass.blockout.rawValue),
            ])
        })
    }

    // MARK: - Validate

    private static func registerValidate(on server: MCPServer, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_validate_spec", group: .sculpt,
            description: "Validate the authored spec. Schema errors always block; with strictQuality:true it also blocks specs too shallow for the assessed complexity (unmapped details, too few components, missing materials). On failure this returns an isError result listing the issues to fix.",
            inputSchema: Schema.object([
                "strictQuality": Schema.boolean("also enforce the strict-quality bar (default true)"),
            ])
        ) { args in
            guard let spec = await store.spec else {
                throw ToolError.failed("no spec authored yet — call sculpt_author_spec first")
            }
            let strict = args["strictQuality"].boolValue ?? true
            let assessment = await store.assessment
            let result = SpecValidator.validate(spec, assessment: assessment, strictQuality: strict)
            if !result.isValid {
                throw ToolError.rejectedByValidation(result.errors.map(\.message))
            }
            return .object([
                "valid": .bool(true),
                "warnings": .array(result.warnings.map { .string($0.message) }),
            ])
        })
    }

    // MARK: - Build pass

    private static func registerBuild(on server: MCPServer, session: EditSession, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_build_pass", group: .sculpt,
            description: "Realize the current locked pass into the stage. Blockout authors geometry (with repetition copies), structural places components, material binds materials; the other passes are review-only and author nothing. Each step funnels through the edit stack (undoable). Returns the authored prim paths.",
            inputSchema: Schema.object([:])
        ) { _ in
            guard let spec = await store.spec, let orchestrator = await store.orchestrator else {
                throw ToolError.failed("no spec authored yet — call sculpt_author_spec first")
            }
            let pass = orchestrator.current
            // Action-ready gate: the interaction pass only authors once the
            // object exposes a usable runtime layer (img2threejs's gate).
            if pass == .interaction {
                let ready = SpecValidator.actionReady(spec)
                if !ready.isValid {
                    throw ToolError.rejectedByValidation(ready.errors.map(\.message))
                }
            }
            let steps = BuildPlanner.plan(for: spec, pass: pass)
            var authored: [String] = []
            for step in steps {
                if let path = try await execute(step: step, session: session) {
                    authored.append(path)
                }
            }
            return .object([
                "pass": .string(pass.rawValue),
                "stepCount": .number(Double(steps.count)),
                "authored": .array(authored.map { .string($0) }),
                "reviewOnly": .bool(steps.isEmpty),
            ])
        })
    }

    // MARK: - Review

    private static func registerReview(on server: MCPServer, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_review", group: .sculpt,
            description: "Record the agent's visual judgment of the current pass and advance the pipeline. decision: continue | refineSpec | refineCode | requestInput | stop. `continue` requires a render, a comparison sheet, and a score >= the assessed acceptance threshold; otherwise it is rejected. Optional `featureScores` (detailItemId → 0...1) records per-feature scores; a `continue` out of the final pass must clear every declared per-feature threshold.",
            inputSchema: Schema.object([
                "decision": Schema.string("continue | refineSpec | refineCode | requestInput | stop"),
                "score": Schema.number("vision score 0...1 (required to continue)"),
                "renderPath": Schema.string("path to the pass render (required to continue)"),
                "comparisonSheetPath": Schema.string("path to the reference-vs-render sheet (required to continue)"),
                "note": Schema.string("optional reviewer note"),
                "featureScores": .object(["type": "object", "description": "map of detail-item id → vision score (0...1)"]),
            ], required: ["decision"])
        ) { args in
            guard let decisionRaw = args["decision"].stringValue,
                  let decision = PassDecision(rawValue: decisionRaw) else {
                throw ToolError.invalidParams("'decision' must be one of continue, refineSpec, refineCode, requestInput, stop")
            }
            let threshold = await store.assessment?.policy.minScore ?? 0.7
            let result = try await store.review(
                decision: decision, score: args["score"].doubleValue,
                renderPath: args["renderPath"].stringValue,
                comparisonSheetPath: args["comparisonSheetPath"].stringValue,
                note: args["note"].stringValue, threshold: threshold,
                featureScores: featureScores(from: args["featureScores"]))
            return advanceResultJSON(result)
        })
    }

    // MARK: - Status

    private static func registerStatus(on server: MCPServer, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_status", group: .sculpt,
            description: "Report pipeline state: current pass, complete/halted flags, completed-pass count, unmapped detail items, and the last recorded score.",
            inputSchema: Schema.object([:])
        ) { _ in
            guard let spec = await store.spec, let orchestrator = await store.orchestrator else {
                return .object(["initialized": .bool(false)])
            }
            let unmapped = spec.detailInventory.unmapped.map(\.id)
            return .object([
                "initialized": .bool(true),
                "currentPass": .string(orchestrator.current.rawValue),
                "isComplete": .bool(orchestrator.isComplete),
                "isHalted": .bool(orchestrator.isHalted),
                "reviewCount": .number(Double(spec.reviewHistory.count)),
                "unmappedDetails": .array(unmapped.map { .string($0) }),
                "socketCount": .number(Double(spec.sockets.count)),
                "colliderCount": .number(Double(spec.colliders.count)),
                "lightCount": .number(Double(spec.lights.count)),
                "lodTierCount": .number(Double(spec.lodTiers.count)),
                "actionReady": .bool(SpecValidator.actionReady(spec).isValid),
                "featuresAccepted": .bool(SpecValidator.featureAcceptance(spec).isValid),
                "unacceptedFeatures": .array(spec.detailInventory.unaccepted.map { .string($0.id) }),
                "lastScore": spec.reviewHistory.last?.score.map { .number($0) } ?? .null,
            ])
        })
    }

    // MARK: - Comparison sheet

    private static func registerComparisonSheet(on server: MCPServer, store: SculptStore, workDirectory: URL) {
        server.register(MCPTool(
            name: "sculpt_comparison_sheet", group: .sculpt,
            description: "Compose a reference-vs-render comparison sheet for the current pass (img2threejs's screenshot-review artifact). Writes an SVG placing the reference beside the pass render to the work directory and returns its path — feed that path plus your fidelity score to sculpt_review.",
            inputSchema: Schema.object([
                "referencePath": Schema.string("path to the original reference image"),
                "renderPath": Schema.string("path to the current pass render"),
                "size": Schema.integer("per-panel pixel size (default 512)"),
            ], required: ["referencePath", "renderPath"])
        ) { args in
            guard let orchestrator = await store.orchestrator else {
                throw ToolError.failed("no spec authored yet — call sculpt_author_spec first")
            }
            guard let referencePath = args["referencePath"].stringValue,
                  let renderPath = args["renderPath"].stringValue else {
                throw ToolError.invalidParams("'referencePath' and 'renderPath' are required")
            }
            let sheet = ComparisonSheet(
                pass: orchestrator.current, referencePath: referencePath,
                renderPath: renderPath, size: args["size"].intValue ?? 512)
            let path = try writeComparisonSheet(sheet, to: workDirectory)
            return .object([
                "pass": .string(sheet.pass.rawValue),
                "comparisonSheetPath": .string(path),
            ])
        })
    }

    static func writeComparisonSheet(_ sheet: ComparisonSheet, to workDirectory: URL) throws -> String {
        let url = workDirectory.appendingPathComponent("comparison-\(sheet.pass.rawValue).svg")
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try Data(sheet.svg().utf8).write(to: url)
        } catch {
            // coverage:disable — filesystem write failure (read-only/full disk) is environmental, not a code path we can exercise deterministically.
            throw ToolError.failed("could not write comparison sheet: \(error)")
            // coverage:enable
        }
        return url.path
    }

    // MARK: - Step execution

    /// Realize one build step through the session's mutation funnel. Returns
    /// the authored/affected prim path (for geometry and materials).
    static func execute(step: BuildStep, session: EditSession) async throws -> String? {
        switch step {
        case .createGroup(let name, let parentPath):
            let args = insertArgs(name: name, parent: parentPath)
            let built = try MutateTools.makeInsert(args: args, session: session, extraAttributes: [])
            _ = try session.mutate(built.command)
            return built.path.description

        case let .createMesh(name, parentPath, primitive, width, height, depth, radius, segments):
            let mesh = try buildPrimitive(primitive, width: width, height: height, depth: depth,
                                          radius: radius, segments: segments)
            return try insertMesh(mesh, name: name, parentPath: parentPath, session: session)

        case .createLibraryMesh(let name, let parentPath, let entryID):
            guard let entry = ShapeLibrary.entry(id: entryID) else {
                throw ToolError.invalidParams("unknown library entry '\(entryID)'")
            }
            let mesh: HalfEdgeMesh
            do { mesh = try entry.build() }
            catch {
                // coverage:disable — built-in prefabs are constructed from validated recipes and do not throw; kept so a future broken prefab surfaces structurally.
                throw ToolError.failed("library entry '\(entryID)' failed to build: \(error)")
                // coverage:enable
            }
            return try insertMesh(mesh, name: name, parentPath: parentPath, session: session)

        case let .setTransform(path, translation, rotation, scale):
            let primPath = try resolvePath(path, session: session)
            let trs = TRS(translation: translation, rotationEulerDegrees: rotation, scale: scale)
            let old = session.stage.prim(at: primPath)?.attribute(named: transformAttributeName)
            _ = try session.mutate(SetTransformCommand(path: primPath, newTRS: trs, oldAttribute: old))
            return primPath.description

        case .createMaterial(let targetPath, let material):
            let primPath = try resolvePath(targetPath, session: session)
            guard let command = CreateMaterialCommand.make(bindingTo: primPath, baseColor: material.baseColor, in: session.stage) else {
                // coverage:disable — make() returns nil only for a missing target, which resolvePath already rejects.
                throw ToolError.invalidParams("cannot bind material to \(targetPath)")
                // coverage:enable
            }
            _ = try session.mutate(command)
            // Author the remaining PBR channels (scalars + texture maps) onto
            // the surface shader created above, each as its own undoable edit.
            for attribute in materialChannelAttributes(material) {
                try authorAttribute(attribute, on: command.surfacePath, session: session)
            }
            return command.materialPath.description

        case let .createLight(name, parentPath, kind, intensity, color):
            let args = insertArgs(name: name, parent: parentPath)
            let built = try MutateTools.makeInsert(
                args: args, session: session,
                extraAttributes: [
                    Attribute(name: "inputs:intensity", value: .double(intensity)),
                    Attribute(name: "inputs:color", value: .vector(color)),
                ],
                typeOverride: kind.usdTypeName)
            _ = try session.mutate(built.command)
            return built.path.description

        case .projectTexture(let rootPath, let descriptorJSON):
            return try authorRootAttribute(
                name: "sculptProjectedTexture", value: descriptorJSON,
                rootPath: rootPath, session: session)

        case .authorLOD(let rootPath, let manifestJSON):
            return try authorRootAttribute(
                name: "sculptLOD", value: manifestJSON,
                rootPath: rootPath, session: session)

        case .authorRuntime(let rootPath, let manifestJSON):
            return try authorRootAttribute(
                name: "sculptRuntime", value: manifestJSON,
                rootPath: rootPath, session: session)
        }
    }

    /// The extra shader-input attributes for a material beyond the base colour
    /// authored by `CreateMaterialCommand`: roughness/metallic scalars, an
    /// optional emissive colour, and any texture-map asset paths + normal scale.
    static func materialChannelAttributes(_ material: MaterialSpec) -> [Attribute] {
        var attributes: [Attribute] = [
            Attribute(name: "inputs:roughness", value: .double(material.roughness)),
            Attribute(name: "inputs:metallic", value: .double(material.metallic)),
        ]
        if let emissive = material.emissive {
            attributes.append(Attribute(name: "inputs:emissiveColor", value: .vector(emissive)))
        }
        let maps: [(String?, String)] = [
            (material.albedoMap, "inputs:albedoMap"), (material.normalMap, "inputs:normalMap"),
            (material.roughnessMap, "inputs:roughnessMap"), (material.emissiveMap, "inputs:emissiveMap"),
        ]
        for (path, name) in maps {
            if let path { attributes.append(Attribute(name: name, value: .string(path))) }
        }
        if let scale = material.normalScale {
            attributes.append(Attribute(name: "inputs:normalScale", value: .double(scale)))
        }
        return attributes
    }

    /// Set one attribute on an existing prim through the mutation funnel.
    static func authorAttribute(_ attribute: Attribute, on path: PrimPath, session: EditSession) throws {
        let old = session.stage.prim(at: path)?.attribute(named: attribute.name)
        _ = try session.mutate(SetAttributeCommand(path: path, newAttribute: attribute, oldAttribute: old))
    }

    /// Author a string attribute onto the resolved sculpt-root prim (shared by
    /// the runtime-manifest and projected-texture descriptor steps).
    static func authorRootAttribute(name: String, value: String, rootPath: String, session: EditSession) throws -> String {
        let primPath = try resolvePath(rootPath, session: session)
        try authorAttribute(Attribute(name: name, value: .string(value)), on: primPath, session: session)
        return primPath.description
    }

    static func insertMesh(_ mesh: HalfEdgeMesh, name: String, parentPath: String?, session: EditSession) throws -> String {
        let flat = MeshIO.flat(from: mesh)
        let args = insertArgs(name: name, parent: parentPath)
        let built = try MutateTools.makeInsert(
            args: args, session: session,
            extraAttributes: GeometryProbe.meshAttributes(from: flat),
            typeOverride: "Mesh")
        _ = try session.mutate(built.command)
        return built.path.description
    }

    static func buildPrimitive(
        _ primitive: ShapeKind.Primitive,
        width: Double, height: Double, depth: Double, radius: Double, segments: Int
    ) throws -> HalfEdgeMesh {
        do {
            switch primitive {
            case .plane: return try Primitives.plane(width: width, depth: depth)
            case .box: return try Primitives.box(width: width, height: height, depth: depth)
            case .cylinder: return try Primitives.cylinder(radius: radius, height: height, radialSegments: segments)
            case .cone: return try Primitives.cone(radius: radius, height: height, radialSegments: segments)
            case .sphere: return try Primitives.uvSphere(radius: radius, rings: max(3, segments / 2), segments: segments)
            }
        } catch {
            // coverage:disable — Primitives throw only on degenerate parameters; specs reaching build have positive dims and segments >= 3. Kept so a new primitive's failure surfaces structurally.
            throw ToolError.failed("primitive construction failed: \(error)")
            // coverage:enable
        }
    }

    /// Resolve a "/A/B" path string to an existing prim path.
    static func resolvePath(_ raw: String, session: EditSession) throws -> PrimPath {
        try session.resolve(.object(["path": .string(raw)]))
    }

    static func insertArgs(name: String, parent: String?) -> JSONValue {
        var dict: [String: JSONValue] = ["name": .string(name)]
        if let parent { dict["parent"] = .string(parent) }
        return .object(dict)
    }

    // MARK: - JSON

    /// Parse an optional `featureScores` object argument into a numeric map,
    /// keeping only entries with a numeric value.
    static func featureScores(from value: JSONValue) -> [String: Double] {
        guard let object = value.objectValue else { return [:] }
        return object.compactMapValues { $0.doubleValue }
    }

    static func probeReportJSON(_ report: ProbeReport) -> JSONValue {
        .object([
            "verdict": .string(report.verdict.rawValue),
            "width": .number(Double(report.width)),
            "height": .number(Double(report.height)),
            "megapixels": .number(report.megapixels),
            "aspectRatio": .number(report.aspectRatio),
            "recommendedMaxComponents": .number(Double(report.recommendedMaxComponents)),
            "reasons": .array(report.reasons.map { .string($0) }),
        ])
    }

    static func assessmentJSON(_ a: PreSpecAssessment) -> JSONValue {
        .object([
            "suitability": .object([
                "verdict": .string(a.suitability.suitability.rawValue),
                "reasons": .array(a.suitability.reasons.map { .string($0) }),
            ]),
            "objectClass": .string(a.objectClass.rawValue),
            "complexity": .number(Double(a.complexity)),
            "policy": .object([
                "minScore": .number(a.policy.minScore),
                "minDetailItems": .number(Double(a.policy.minDetailItems)),
                "minComponents": .number(Double(a.policy.minComponents)),
                "requireMaterials": .bool(a.policy.requireMaterials),
            ]),
            "notes": .array(a.notes.map { .string($0) }),
        ])
    }

    static func advanceResultJSON(_ result: AdvanceResult) -> JSONValue {
        switch result {
        case .advanced(let pass):
            return .object(["result": "advanced", "currentPass": .string(pass.rawValue)])
        case .completed:
            return .object(["result": "completed"])
        case .staying(let pass):
            return .object(["result": "staying", "currentPass": .string(pass.rawValue)])
        case .awaitingInput(let pass):
            return .object(["result": "awaitingInput", "currentPass": .string(pass.rawValue)])
        case .halted(let pass):
            return .object(["result": "halted", "currentPass": .string(pass.rawValue)])
        }
    }

    static func persist(_ spec: ObjectSculptSpec, to workDirectory: URL) {
        guard let data = try? spec.encoded() else { return }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try? data.write(to: workDirectory.appendingPathComponent("sculpt-spec.json"))
    }
}
