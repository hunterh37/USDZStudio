import Foundation
import EditingKit
import MeshKit
import SculptKit
import USDCore
import ValidationKit

/// Cross-call state for the staged-sculpt pipeline: the pre-spec assessment,
/// the authored spec, and the locked-pass orchestrator. Requests are processed
/// serially by the transport loop, but this is an `actor` so the async tool
/// handlers can share it safely.
public actor SculptStore {
    public private(set) var assessment: PreSpecAssessment?
    public private(set) var spec: ObjectSculptSpec?
    public private(set) var orchestrator: PassOrchestrator?
    /// Where pipeline state is persisted so a sculpt survives a server restart.
    /// nil disables persistence (used by tests that want an ephemeral store).
    let workDirectory: URL?

    public init(workDirectory: URL? = nil) {
        self.workDirectory = workDirectory
        // Best-effort restore: reload a previously-persisted assessment, spec,
        // and pass position so the pipeline resumes where it left off instead of
        // silently dropping back to the blockout pass.
        guard let dir = workDirectory else { return }
        if let data = try? Data(contentsOf: Self.assessmentURL(dir)) {
            assessment = try? JSONDecoder().decode(PreSpecAssessment.self, from: data)
        }
        if let data = try? Data(contentsOf: Self.specURL(dir)),
           let restored = try? ObjectSculptSpec.decoded(from: data) {
            spec = restored
            if let odata = try? Data(contentsOf: Self.orchestratorURL(dir)),
               let restoredOrchestrator = try? JSONDecoder().decode(PassOrchestrator.self, from: odata) {
                orchestrator = restoredOrchestrator
            } else {
                // Spec present but the orchestrator file is missing/corrupt (a
                // partial write, or a crash between the two persists): recover
                // by restarting the pass machine at blockout rather than
                // stranding the restored spec with no orchestrator.
                orchestrator = PassOrchestrator()
            }
        }
    }

    /// True when the pipeline is on its last pass (a `continue` here completes
    /// the object). Used to trigger the AR-compliance completion gate.
    var isFinalPass: Bool {
        guard let orchestrator else { return false }
        return orchestrator.isActive && orchestrator.current.next == nil
    }

    func setAssessment(_ a: PreSpecAssessment) {
        assessment = a
        persistAssessment()
    }

    func setSpec(_ s: ObjectSculptSpec) {
        spec = s
        orchestrator = PassOrchestrator()
        persistSpec()
        persistOrchestrator()
    }

    /// Build a review for the current pass, record it, and advance the
    /// orchestrator. Optionally records per-feature review scores first, and —
    /// when this `continue` would complete the pipeline — enforces the
    /// feature-acceptance gate. Enforces the measured-similarity floor via
    /// `similarityFloor`. Persists the updated spec + pass position. Returns the
    /// advance result, or throws if no spec exists yet or a gate rejects.
    func review(
        decision: PassDecision, score: Double?, renderPath: String?,
        comparisonSheetPath: String?, measuredSimilarity: Double?, note: String?,
        threshold: Double, similarityFloor: Double,
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
            renderPath: renderPath, comparisonSheetPath: comparisonSheetPath,
            measuredSimilarity: measuredSimilarity, note: note)
        spec!.reviewHistory.append(review)
        do {
            let result = try orchestrator!.advance(
                after: review, threshold: threshold, similarityFloor: similarityFloor)
            persistSpec()
            persistOrchestrator()
            return result
        } catch let error as AdvanceError {
            throw ToolError.invalidParams("\(error)")
        }
    }

    // MARK: - Persistence

    static func assessmentURL(_ dir: URL) -> URL { dir.appendingPathComponent("sculpt-assessment.json") }
    static func specURL(_ dir: URL) -> URL { dir.appendingPathComponent("sculpt-spec.json") }
    static func orchestratorURL(_ dir: URL) -> URL { dir.appendingPathComponent("sculpt-orchestrator.json") }

    func persistAssessment() {
        guard let dir = workDirectory, let assessment,
              let data = try? JSONEncoder().encode(assessment) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.assessmentURL(dir))
    }

    func persistSpec() {
        guard let dir = workDirectory, let spec, let data = try? spec.encoded() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.specURL(dir))
    }

    func persistOrchestrator() {
        guard let dir = workDirectory, let orchestrator,
              let data = try? JSONEncoder().encode(orchestrator) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.orchestratorURL(dir))
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
        registerAuthor(on: server, store: store)
        registerValidate(on: server, store: store)
        registerBuild(on: server, session: session, store: store)
        registerReview(on: server, session: session, store: store)
        registerStatus(on: server, store: store)
        registerComparisonSheet(on: server, store: store, workDirectory: workDirectory)
    }

    /// Resolve reference-image dimensions from an optional decoded `imagePath`
    /// (falling back to explicit `width`/`height` args). When a path is given it
    /// is decoded for real (via `RasterLoader`), so the intake vets the actual
    /// pixels instead of trusting agent-reported numbers. Throws when a supplied
    /// path can't be decoded and no usable explicit dimensions are present.
    static func resolveImageDimensions(
        _ args: JSONValue
    ) throws -> (width: Int, height: Int, hasAlpha: Bool?) {
        if let path = args["imagePath"].stringValue {
            if let info = RasterLoader.info(path: path) {
                return (info.width, info.height, info.hasAlpha)
            }
            throw ToolError.invalidParams("could not decode image at '\(path)'")
        }
        let width = args["width"].intValue ?? 0
        let height = args["height"].intValue ?? 0
        guard width > 0, height > 0 else {
            throw ToolError.invalidParams("'width' and 'height' must be positive (or supply 'imagePath')")
        }
        return (width, height, args["hasAlpha"].boolValue)
    }

    // MARK: - Probe

    private static func registerProbe(on server: MCPServer) {
        server.register(MCPTool(
            name: "sculpt_probe", group: .sculpt,
            description: "Technical fitness probe of a reference image (img2threejs's probe_image intake). Vets pixel dimensions — and alpha — before assessment: returns a usable/marginal/unusable verdict, megapixels, aspect ratio, a recommended component ceiling, and the reasons. Prefer 'imagePath' (the image is decoded for true dimensions + alpha); or supply width/height (and hasAlpha) directly.",
            inputSchema: Schema.object([
                "imagePath": Schema.string("path to the reference image — decoded for true dimensions + alpha (preferred)"),
                "width": Schema.integer("reference image width in pixels (used when imagePath is absent)"),
                "height": Schema.integer("reference image height in pixels (used when imagePath is absent)"),
                "hasAlpha": Schema.boolean("whether the source carries a transparency channel (optional)"),
            ])
        ) { args in
            let (width, height, hasAlpha) = try resolveImageDimensions(args)
            let report = ImageProbe.probe(width: width, height: height, hasAlpha: hasAlpha)
            return probeReportJSON(report)
        })
    }

    // MARK: - Assess

    private static func registerAssess(on server: MCPServer, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_assess", group: .sculpt,
            description: "Pre-spec assessment of a reference image: classify (character/object/hybrid), score complexity, and set the acceptance policy (thresholds — including the measured-similarity floor — the strict-quality gate and review loop enforce). Deterministic from descriptive hints + image dimensions. Prefer 'imagePath' (decoded for true dimensions) or supply width/height.",
            inputSchema: Schema.object([
                "hints": Schema.array(of: Schema.string("descriptive tag"), "descriptive tags, e.g. 'wooden barrel', 'rusty', 'glossy'"),
                "imagePath": Schema.string("path to the reference image — decoded for true dimensions (preferred)"),
                "width": Schema.integer("reference image width in pixels (used when imagePath is absent)"),
                "height": Schema.integer("reference image height in pixels (used when imagePath is absent)"),
            ], required: ["hints"])
        ) { args in
            let hints = args["hints"].stringArrayValue ?? []
            let (width, height, _) = try resolveImageDimensions(args)
            let assessment = PreSpecAssessment.assess(hints: hints, width: width, height: height)
            await store.setAssessment(assessment)
            return assessmentJSON(assessment)
        })
    }

    // MARK: - Author spec

    private static func registerAuthor(on server: MCPServer, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_author_spec", group: .sculpt,
            description: """
                Author (or replace) the ObjectSculptSpec and reset the pass orchestrator to blockout. Pass the full spec as JSON under `spec`.

                Shape (SculptKit.ObjectSculptSpec): {
                  "name": String, "objectClass": "character"|"object"|"hybrid",
                  "root": ComponentNode, "materials": [MaterialSpec], "sockets": [Socket],
                  "joints": [Joint], "detailInventory": {...}, … (all but name/objectClass/root optional)
                }
                ComponentNode: { "name": String, "shape": ShapeKind, "translation":[x,y,z], "rotationEulerDegrees":[x,y,z], "scale":[x,y,z], "width"/"height"/"depth"/"radius"/"segments": Number, "materialID": String?, "attachment": "root"|"weld"|"socket"|"pin"|"free", "children":[ComponentNode] }
                ShapeKind is a tagged object — one of: {"kind":"group"}, {"kind":"primitive","primitive":"box"|"plane"|"cylinder"|"cone"|"sphere"}, {"kind":"library","entryID":"…"}.

                Every geometry component except the root should declare `attachment` (root/weld/socket/pin) — a component without one is flagged here as a warning and rejected by strict validate. For parts that realistically open/swing (lid, door, cap, drawer) declare `joints` (revolute hinge / prismatic slider with an axis + pivot targeting a component) so the interaction pass authors real articulation.
                """,
            inputSchema: Schema.object([
                "spec": .object(["type": "object", "description": "the full ObjectSculptSpec JSON (see tool description for the schema + a minimal example)"]),
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
                throw ToolError.invalidParams("could not decode spec: \(decodeHint(error))")
            }
            await store.setSpec(spec)
            // Surface the attachment requirement now (issue #113): a geometry
            // component with no `attachment` still decodes, but strict validate
            // rejects it — warn here so it isn't a surprise later, all at once.
            let floating = SpecValidator.componentsMissingAttachment(spec)
            var warnings: [JSONValue] = []
            if !floating.isEmpty {
                warnings.append(.string(
                    "components missing an attachment (declare root/weld/socket/pin, else strict validate rejects them): "
                    + floating.joined(separator: ", ")))
            }
            return .object([
                "name": .string(spec.name),
                "componentCount": .number(Double(spec.componentCount)),
                "materialCount": .number(Double(spec.materials.count)),
                "detailItems": .number(Double(spec.detailInventory.items.count)),
                "currentPass": .string(SculptPass.blockout.rawValue),
                "warnings": .array(warnings),
            ])
        })
    }

    /// Turn a raw `DecodingError` into an actionable message that names the
    /// offending key/path, instead of the cryptic `keyNotFound(CodingKeys(...))`
    /// dump agents saw before (#112).
    static func decodeHint(for error: Error) -> String {
        func pathString(_ path: [CodingKey]) -> String {
            path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        guard let decodingError = error as? DecodingError else {
            return "could not decode spec: \(error)"
        }
        switch decodingError {
        case .keyNotFound(let key, let ctx):
            let loc = pathString(ctx.codingPath)
            let at = loc.isEmpty ? "at the top level" : "under '\(loc)'"
            return "spec is missing required key '\(key.stringValue)' \(at). Required top-level keys: name, objectClass, root. See the tool description for the full schema + example."
        case .typeMismatch(let type, let ctx):
            return "spec has the wrong type for '\(pathString(ctx.codingPath))' (expected \(type)). \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            return "spec has a null where a value is required at '\(pathString(ctx.codingPath))'. \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            let loc = pathString(ctx.codingPath)
            return "spec is malformed\(loc.isEmpty ? "" : " at '\(loc)'"): \(ctx.debugDescription)"
        // coverage:disable — @unknown default guards future DecodingError cases; unreachable with today's enum.
        @unknown default:
            return "could not decode spec: \(decodingError)"
        // coverage:enable
        }
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
            // Contamination warning (issue #114): when blockout authors into a
            // stage that already holds prims outside the sculpt subtree, that
            // foreign geometry skews scene_stats / render bounds / silhouette
            // similarity. Warn (don't block — the operator may want it there).
            var warnings: [JSONValue] = []
            if pass == .blockout {
                let foreign = session.stage.rootPrims
                    .map(\.name)
                    .filter { $0 != spec.root.name }
                if !foreign.isEmpty {
                    warnings.append(.string(
                        "target stage is not empty — unrelated prims will skew bounds/similarity: "
                        + foreign.joined(separator: ", ")))
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
                "warnings": .array(warnings),
            ])
        })
    }

    // MARK: - Review

    private static func registerReview(on server: MCPServer, session: EditSession, store: SculptStore) {
        server.register(MCPTool(
            name: "sculpt_review", group: .sculpt,
            description: "Record the agent's visual judgment of the current pass and advance the pipeline. decision: continue | refineSpec | refineCode | requestInput | stop. `continue` requires a render, a comparison sheet, a subjective score >= the assessed acceptance threshold, AND (when the assessment sets a similarity floor) a `measuredSimilarity` >= that floor — the deterministic gate the score cannot bypass. Optional `featureScores` (detailItemId → 0...1) records per-feature scores; a `continue` out of the FINAL pass must clear every per-feature threshold and pass the AR-compliance gate (the finished stage is validated against the ARKit profile). Pass the `measuredSimilarity` returned by sculpt_comparison_sheet.",
            inputSchema: Schema.object([
                "decision": Schema.string("continue | refineSpec | refineCode | requestInput | stop"),
                "score": Schema.number("vision score 0...1 (required to continue)"),
                "renderPath": Schema.string("path to the pass render (required to continue)"),
                "comparisonSheetPath": Schema.string("path to the reference-vs-render sheet (required to continue)"),
                "measuredSimilarity": Schema.number("deterministic similarity from sculpt_comparison_sheet (required to continue when a floor is set)"),
                "note": Schema.string("optional reviewer note"),
                "featureScores": .object(["type": "object", "description": "map of detail-item id → vision score (0...1)"]),
            ], required: ["decision"])
        ) { args in
            guard let decisionRaw = args["decision"].stringValue,
                  let decision = PassDecision(rawValue: decisionRaw) else {
                throw ToolError.invalidParams("'decision' must be one of continue, refineSpec, refineCode, requestInput, stop")
            }
            let policy = await store.assessment?.policy
            let threshold = policy?.minScore ?? 0.7
            let similarityFloor = policy?.similarityFloor ?? 0

            // AR-compliance completion gate: when the assessment requires it, a
            // `continue` out of the final pass must yield an AR-valid stage.
            // Checked before the pass is recorded so a non-compliant object
            // cannot be marked complete.
            if decision == .continue, policy?.requireCompliance == true, await store.isFinalPass {
                let compliance = ComplianceChecker(profile: .arkit).check(session.stage)
                if !compliance.isExportAllowed {
                    throw ToolError.rejectedByValidation(
                        ["AR-compliance gate: \(compliance.summary)"]
                        + compliance.blockingDiagnostics.map { "  • \($0.message)" })
                }
            }

            let result = try await store.review(
                decision: decision, score: args["score"].doubleValue,
                renderPath: args["renderPath"].stringValue,
                comparisonSheetPath: args["comparisonSheetPath"].stringValue,
                measuredSimilarity: args["measuredSimilarity"].doubleValue,
                note: args["note"].stringValue, threshold: threshold,
                similarityFloor: similarityFloor,
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
            let unaccepted = spec.detailInventory.unaccepted.map { JSONValue.string($0.id) }
            let lastReview = spec.reviewHistory.last
            let similarityFloor = await store.assessment?.policy.similarityFloor
            // Built incrementally rather than as one large dictionary literal to
            // keep the Swift type-checker within its expression budget.
            var status: [String: JSONValue] = [:]
            status["initialized"] = .bool(true)
            status["currentPass"] = .string(orchestrator.current.rawValue)
            status["isComplete"] = .bool(orchestrator.isComplete)
            status["isHalted"] = .bool(orchestrator.isHalted)
            status["reviewCount"] = .number(Double(spec.reviewHistory.count))
            status["unmappedDetails"] = .array(unmapped.map { .string($0) })
            status["socketCount"] = .number(Double(spec.sockets.count))
            status["colliderCount"] = .number(Double(spec.colliders.count))
            status["lightCount"] = .number(Double(spec.lights.count))
            status["lodTierCount"] = .number(Double(spec.lodTiers.count))
            status["actionReady"] = .bool(SpecValidator.actionReady(spec).isValid)
            status["featuresAccepted"] = .bool(SpecValidator.featureAcceptance(spec).isValid)
            status["unacceptedFeatures"] = .array(unaccepted)
            status["lastScore"] = lastReview?.score.map { .number($0) } ?? .null
            status["lastMeasuredSimilarity"] = lastReview?.measuredSimilarity.map { .number($0) } ?? .null
            status["similarityFloor"] = similarityFloor.map { .number($0) } ?? .null
            return .object(status)
        })
    }

    // MARK: - Comparison sheet

    private static func registerComparisonSheet(on server: MCPServer, store: SculptStore, workDirectory: URL) {
        server.register(MCPTool(
            name: "sculpt_comparison_sheet", group: .sculpt,
            description: "Compose a reference-vs-render comparison sheet for the current pass (img2threejs's screenshot-review artifact) AND measure fidelity deterministically. Accepts a single reference/render pair, or a multi-view turntable via 'views' (each {label, referencePath, renderPath}) — the measured similarity is the WORST view, so a good angle can't hide a bad one. Writes an SVG to the work directory and, when the images decode, returns 'measuredSimilarity' (a shape-dominant blend of a concavity-preserving shapeScore and an appearanceScore) plus the shape/appearance split and per-metric detail. Feed the returned comparisonSheetPath and measuredSimilarity to sculpt_review — the continue-gate enforces the assessed similarity floor.",
            inputSchema: Schema.object([
                "referencePath": Schema.string("path to the original reference image (single-view)"),
                "renderPath": Schema.string("path to the current pass render (single-view)"),
                "views": Schema.array(
                    of: .object(["type": "object", "description": "{label, referencePath, renderPath}"]),
                    "multi-view pairs; overrides referencePath/renderPath when present"),
                "size": Schema.integer("per-panel pixel size (default 512)"),
            ])
        ) { args in
            guard let orchestrator = await store.orchestrator else {
                throw ToolError.failed("no spec authored yet — call sculpt_author_spec first")
            }
            let views = try comparisonViews(from: args)
            let sheet = ComparisonSheet(
                pass: orchestrator.current, views: views, size: args["size"].intValue ?? 512)
            let path = try writeComparisonSheet(sheet, to: workDirectory)
            var result: [String: JSONValue] = [
                "pass": .string(sheet.pass.rawValue),
                "comparisonSheetPath": .string(path),
                "viewCount": .number(Double(views.count)),
            ]
            // Deterministic fidelity measurement across every view (worst wins).
            let pairs = views.map { (reference: $0.referencePath, render: $0.renderPath) }
            if let report = RasterLoader.worstViewSimilarity(pairs) {
                result["measuredSimilarity"] = .number(report.aggregate)
                result["similarity"] = similarityReportJSON(report)
            } else {
                result["measuredSimilarity"] = .null
                result["similarityNote"] = .string(
                    "images could not be decoded — the measured floor cannot be enforced for this pass")
            }
            return .object(result)
        })
    }

    /// Build the comparison views from either an explicit `views` array or the
    /// single-pair `referencePath`/`renderPath` args. Throws when neither a
    /// usable multi-view list nor a complete single pair is present.
    static func comparisonViews(from args: JSONValue) throws -> [ComparisonView] {
        if case .array(let rawViews) = args["views"], !rawViews.isEmpty {
            var views: [ComparisonView] = []
            for (index, raw) in rawViews.enumerated() {
                guard let reference = raw["referencePath"].stringValue,
                      let render = raw["renderPath"].stringValue else {
                    throw ToolError.invalidParams(
                        "views[\(index)] needs 'referencePath' and 'renderPath'")
                }
                let label = raw["label"].stringValue ?? "view\(index + 1)"
                views.append(ComparisonView(label: label, referencePath: reference, renderPath: render))
            }
            return views
        }
        guard let referencePath = args["referencePath"].stringValue,
              let renderPath = args["renderPath"].stringValue else {
            throw ToolError.invalidParams(
                "supply 'referencePath' and 'renderPath', or a non-empty 'views' array")
        }
        return [ComparisonView(label: "view", referencePath: referencePath, renderPath: renderPath)]
    }

    static func similarityReportJSON(_ report: SimilarityReport) -> JSONValue {
        .object([
            "aggregate": .number(report.aggregate),
            // Shape / appearance split (#93): the gate's `aggregate` is a
            // shape-dominant blend of these two, so the sheet surfaces both.
            "shapeScore": .number(report.shapeScore),
            "appearanceScore": .number(report.appearanceScore),
            "silhouetteIoU": .number(report.silhouetteIoU),
            "ssim": .number(report.ssim),
            "luminanceCorrelation": .number(report.luminanceCorrelation),
        ])
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
            // Idempotent re-run: a blockout replayed after a partial build (or
            // a review that didn't advance) must not error with "'X' already
            // exists under /" — skip creation and return the existing path so
            // the pass can complete (issue #111).
            if let existing = existingPath(name: name, parentPath: parentPath, session: session) {
                return existing
            }
            let args = insertArgs(name: name, parent: parentPath)
            let built = try MutateTools.makeInsert(args: args, session: session, extraAttributes: [])
            _ = try session.mutate(built.command)
            return built.path.description

        case let .createMesh(name, parentPath, primitive, width, height, depth, radius, segments):
            if let existing = existingPath(name: name, parentPath: parentPath, session: session) {
                return existing
            }
            let mesh = try buildPrimitive(primitive, width: width, height: height, depth: depth,
                                          radius: radius, segments: segments)
            return try insertMesh(mesh, name: name, parentPath: parentPath, session: session)

        case .createLibraryMesh(let name, let parentPath, let entryID):
            if let existing = existingPath(name: name, parentPath: parentPath, session: session) {
                return existing
            }
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

        case .refineMesh(let path, let ops):
            return try applyMeshTransform(at: path, session: session) { mesh in
                var current = mesh
                for op in ops {
                    switch op {
                    case let .inset(fraction, depth):
                        let faces = Set(current.faceLoops.keys)
                        current = try InsetFaces.apply(
                            current, selection: .faces(faces),
                            params: .init(fraction: fraction, depth: depth)).mesh
                    case let .subdivide(levels):
                        let faces = Set(current.faceLoops.keys)
                        current = try SubdivideCatmullClark.apply(
                            current, selection: .faces(faces),
                            params: .init(levels: levels)).mesh
                    }
                }
                return current
            }

        case .decimateMesh(let path, let weldDistance):
            return try applyMeshTransform(at: path, session: session) { mesh in
                let vertices = Set(mesh.positions.keys)
                return try MergeVertices.apply(
                    mesh, selection: .vertices(vertices), params: .byDistance(weldDistance)).mesh
            }
        }
    }

    /// Read an authored prim back into a `HalfEdgeMesh`, apply a transform
    /// (real MeshKit ops), and re-author the resulting topology onto the same
    /// prim through the mutation funnel. Shared by the form-refinement and
    /// optimization passes so their geometry work is genuine, not a manifest.
    static func applyMeshTransform(
        at rawPath: String, session: EditSession,
        _ transform: (HalfEdgeMesh) throws -> HalfEdgeMesh
    ) throws -> String {
        let primPath = try resolvePath(rawPath, session: session)
        guard let prim = session.stage.prim(at: primPath) else {
            // coverage:disable — resolvePath already rejects a missing prim; kept so a future resolver change surfaces structurally.
            throw ToolError.invalidParams("prim \(rawPath) not found")
            // coverage:enable
        }
        let mesh: HalfEdgeMesh
        do {
            mesh = try MeshIO.mesh(from: GeometryProbe.flatMesh(of: prim))
        } catch {
            throw ToolError.failed("cannot read mesh at \(rawPath): \(error)")
        }
        let result: HalfEdgeMesh
        do {
            result = try transform(mesh)
        } catch {
            throw ToolError.failed("mesh op failed at \(rawPath): \(error)")
        }
        for attribute in GeometryProbe.meshAttributes(from: MeshIO.flat(from: result)) {
            try authorAttribute(attribute, on: primPath, session: session)
        }
        return primPath.description
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

    /// The description of the prim already present at `parentPath`/`name`, or
    /// nil when nothing is there. Lets the create steps be idempotent on a
    /// blockout replay (issue #111).
    static func existingPath(name: String, parentPath: String?, session: EditSession) -> String? {
        let full = (parentPath ?? "") + "/" + name
        guard let path = try? resolvePath(full, session: session),
              session.stage.prim(at: path) != nil else { return nil }
        return path.description
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

    /// Turn a `DecodingError` into a message that names the offending key/path,
    /// so a spec author isn't left with a cryptic `keyNotFound(CodingKeys(...))`
    /// (issue #112). Non-decoding errors pass through unchanged.
    static func decodeHint(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func joinPath(_ path: [CodingKey]) -> String {
            path.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case let .keyNotFound(key, context):
            let at = context.codingPath.isEmpty ? "top level" : joinPath(context.codingPath)
            return "missing required key '\(key.stringValue)' at \(at)"
        case let .typeMismatch(_, context):
            return "type mismatch at \(joinPath(context.codingPath)): \(context.debugDescription)"
        case let .valueNotFound(_, context):
            return "missing value at \(joinPath(context.codingPath)): \(context.debugDescription)"
        case let .dataCorrupted(context):
            let at = context.codingPath.isEmpty ? "top level" : joinPath(context.codingPath)
            return "invalid data at \(at): \(context.debugDescription)"
        @unknown default:
            return "\(decoding)"
        }
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

}
