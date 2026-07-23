import Foundation
import MeshKit
import SculptKit
import USDCore
import ValidationKit

/// §3.3 Verify tools — geometric ground truth after every step, plus the §4
/// closed-loop `score` gate ladder. Gates 1–4 are pure geometry (cheap,
/// exact); renders are reserved for genuinely visual judgments.
public enum VerifyTools {

    public static func register(
        on server: MCPServer, session: EditSession, sculptStore: SculptStore? = nil
    ) {
        server.register(MCPTool(
            name: "validate", group: .verify,
            description: "Run the validation rule catalog over the whole stage. Optional profile: arkit (default) | arkit-strict.",
            inputSchema: Schema.object([
                "profile": Schema.string("validation profile id")
            ])
        ) { args in
            let profile = try profile(from: args, fallback: session.profile)
            return profile.engine.validate(session.stage).asJSON
        })

        server.register(MCPTool(
            name: "check_compliance", group: .verify,
            description: "Check the stage against a compliance profile's export gate. Returns blocking diagnostics and the export verdict.",
            inputSchema: Schema.object([
                "profile": Schema.string("profile id: \(ValidationProfile.identifiers)")
            ])
        ) { args in
            let profile = try profile(from: args, fallback: session.profile)
            let result = ComplianceChecker(profile: profile).check(session.stage)
            return .object([
                "profile": .string(result.profileID),
                "isExportAllowed": .bool(result.isExportAllowed),
                "summary": .string(result.summary),
                "blocking": .array(result.blockingDiagnostics.map(\.asJSON)),
                "report": result.report.asJSON,
            ])
        })

        server.register(MCPTool(
            name: "set_strictness", group: .verify,
            description: "Set the inline post-mutation validation mode: off | warn (default) | strict (rolls back mutations that introduce new errors).",
            inputSchema: Schema.object([
                "mode": Schema.string("off | warn | strict")
            ], required: ["mode"])
        ) { args in
            guard let raw = args["mode"].stringValue,
                  let mode = ValidationStrictness(rawValue: raw)
            else {
                throw ToolError.invalidParams("'mode' must be one of off, warn, strict")
            }
            session.strictness = mode
            return .object(["strictness": .string(mode.rawValue)])
        })

        server.register(MCPTool(
            name: "check_mesh", group: .verify,
            description: "Mesh integrity invariants for one Mesh prim: manifold, closed, winding, degenerate faces. PASS/FAIL with violations.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "allowBoundaries": Schema.boolean("accept open (non-watertight) meshes (default true)"),
            ], required: ["path"])
        ) { args in
            let prim = try session.requirePrim(args)
            return try meshReport(
                of: prim,
                allowBoundaries: args["allowBoundaries"].boolValue ?? true)
        })

        server.register(MCPTool(
            name: "score", group: .verify,
            description: "Closed-loop fidelity gate ladder (schema → mesh integrity → scale sanity → spatial). Returns 0–1 score plus each gate's PASS/FAIL detail; iterate mutate → validate → score until it passes. When a sculpt spec is active, overlaps between components whose spec `attachment` declares intended contact (root/weld/socket/pin) are reported as declaredContacts, not spatial failures — welded parts are expected to interpenetrate.",
            inputSchema: Schema.object([
                "intent": Schema.string("what the agent is building (recorded in the report)"),
                "expectedMaxExtent": Schema.number("plausible real-world max extent in meters (default 50)"),
            ])
        ) { args in
            score(session: session, args: args, spec: await sculptStore?.spec)
        })
    }

    // MARK: - Helpers

    private static func profile(from args: JSONValue, fallback: ValidationProfile) throws -> ValidationProfile {
        guard let id = args["profile"].stringValue else { return fallback }
        guard let named = ValidationProfile.named(id) else {
            throw ToolError.invalidParams("unknown profile '\(id)' (\(ValidationProfile.identifiers))")
        }
        return named
    }

    static func meshReport(of prim: Prim, allowBoundaries: Bool) throws -> JSONValue {
        let flat = try GeometryProbe.flatMesh(of: prim)
        let mesh: HalfEdgeMesh
        do {
            mesh = try MeshIO.mesh(from: flat)
        } catch {
            return .object([
                "pass": .bool(false),
                "violations": .array([
                    .object(["rule": "topology", "detail": .string("\(error)")])
                ]),
            ])
        }
        let violations = MeshInvariants.violations(in: mesh, allowBoundaries: allowBoundaries)
        return .object([
            "pass": .bool(violations.isEmpty),
            "eulerCharacteristic": .number(Double(MeshInvariants.eulerCharacteristic(of: mesh))),
            "violations": .array(violations.map {
                .object(["rule": .string($0.rule), "detail": .string($0.detail)])
            }),
        ])
    }

    /// §4 gate ladder. Gate 5 (visual) is the agent's own judgment over
    /// `render_views` output and is intentionally not scored here. `spec` (the
    /// active sculpt spec, when one exists) informs the spatial gate about
    /// declared-contact parts.
    static func score(session: EditSession, args: JSONValue, spec: ObjectSculptSpec? = nil) -> JSONValue {
        let stage = session.stage
        var gates: [JSONValue] = []
        var passed = 0
        let totalGates = 4.0

        // Gate 1 — schema.
        let report = session.profile.engine.validate(stage)
        let schemaPass = report.errorCount == 0
        if schemaPass { passed += 1 }
        gates.append(.object([
            "gate": "schema", "pass": .bool(schemaPass),
            "errors": .number(Double(report.errorCount)),
            "warnings": .number(Double(report.warningCount)),
        ]))

        // Gate 2 — mesh integrity across every Mesh prim.
        var meshFailures: [JSONValue] = []
        var meshesChecked = 0
        for prim in stage.allPrims() where prim.attribute(named: "faceVertexCounts") != nil {
            meshesChecked += 1
            let verdict = (try? meshReport(of: prim, allowBoundaries: true)) ?? .object(["pass": .bool(false)])
            if verdict["pass"].boolValue != true {
                meshFailures.append(.object([
                    "path": .string(prim.path.description),
                    "violations": verdict["violations"],
                ]))
            }
        }
        let meshPass = meshFailures.isEmpty
        if meshPass { passed += 1 }
        gates.append(.object([
            "gate": "meshIntegrity", "pass": .bool(meshPass),
            "meshesChecked": .number(Double(meshesChecked)),
            "failures": .array(meshFailures),
        ]))

        // Gate 3 — scale sanity: metersPerUnit rule + plausible world extent.
        let mpuDiagnostics = MetersPerUnitRule().evaluate(stage: stage)
        let expectedMax = args["expectedMaxExtent"].doubleValue ?? 50
        var extent = 0.0
        for root in stage.rootPrims {
            if let box = GeometryProbe.worldBBox(of: root.path, in: stage) {
                extent = max(extent, box.maxExtent * stage.metadata.metersPerUnit)
            }
        }
        let scalePass = mpuDiagnostics.isEmpty && extent > 0 && extent <= expectedMax
        if scalePass { passed += 1 }
        gates.append(.object([
            "gate": "scaleSanity", "pass": .bool(scalePass),
            "worldExtentMeters": .number(extent),
            "expectedMaxExtent": .number(expectedMax),
            "diagnostics": .array(mpuDiagnostics.map(\.asJSON)),
        ]))

        // Gate 4 — spatial: no *unintended* interpenetration. An object built
        // the recommended way — overlapping primitives welded into a body —
        // overlaps by design wherever the spec declares an attachment, so
        // those pairs must not fail the gate (issue #161): the gate hunts
        // free-floating/undeclared collisions, not intentional welds.
        let overlaps = GeometryProbe.interpenetrations(in: stage)
        let componentNames = spec?.allComponentNames ?? []
        let contactNames = spec?.declaredContactComponentNames ?? []
        var unintended: [(a: PrimPath, b: PrimPath, overlapVolume: Double)] = []
        var declared: [(a: PrimPath, b: PrimPath, overlapVolume: Double)] = []
        for overlap in overlaps {
            let aName = overlap.a.name, bName = overlap.b.name
            // Declared contact: both prims belong to the spec's component set
            // and at least one of the pair declares a rigid attachment
            // (root/weld/socket/pin) — it is *supposed* to touch its neighbors.
            if componentNames.contains(aName), componentNames.contains(bName),
               contactNames.contains(aName) || contactNames.contains(bName) {
                declared.append(overlap)
            } else {
                unintended.append(overlap)
            }
        }
        let spatialPass = unintended.isEmpty
        if spatialPass { passed += 1 }
        func overlapJSON(_ o: (a: PrimPath, b: PrimPath, overlapVolume: Double)) -> JSONValue {
            .object([
                "a": .string(o.a.description),
                "b": .string(o.b.description),
                "overlapVolume": .number(o.overlapVolume),
            ])
        }
        gates.append(.object([
            "gate": "spatial", "pass": .bool(spatialPass),
            "interpenetrations": .array(unintended.map(overlapJSON)),
            // Informational: overlaps expected by the spec's attachments.
            "declaredContactCount": .number(Double(declared.count)),
            "declaredContacts": .array(declared.map(overlapJSON)),
        ]))

        var payload: [String: JSONValue] = [
            "score": .number(Double(passed) / totalGates),
            "pass": .bool(passed == Int(totalGates)),
            "gates": .array(gates),
            "note": "gate 5 (visual) is agent-judged: call render_views and compare against intent",
        ]
        if let intent = args["intent"].stringValue { payload["intent"] = .string(intent) }
        return .object(payload)
    }
}
