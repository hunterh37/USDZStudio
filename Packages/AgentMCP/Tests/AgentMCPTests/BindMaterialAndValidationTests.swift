import EditingKit
import Foundation
import Testing
import USDCore
import ValidationKit
@testable import AgentMCP

/// `bind_material` tool + batch op (#140/#141) and the compact inline-validation
/// delta (#142).
@Suite struct BindMaterialToolTests {

    @Test func bindMaterialSharesOneMaterialAcrossPrims() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        // Author one material on Box, then bind the SAME material to Lid.
        let created = await callOK(server, "create_material", .object([
            "target": "/Root/Box",
            "baseColor": .array([.number(0.2), .number(0.2), .number(0.2)]),
        ]))
        let materialPath = created["materialPath"].stringValue!

        let bound = await callOK(server, "bind_material", .object([
            "target": "/Root/Lid",
            "materialPath": .string(materialPath),
        ]))
        #expect(bound["materialPath"].stringValue == materialPath)

        // Both prims resolve to the same material — no duplicate /Looks material.
        #expect(MaterialBinding.materialPath(for: PrimPath("/Root/Box")!, in: session.stage)
            == PrimPath(materialPath))
        #expect(MaterialBinding.materialPath(for: PrimPath("/Root/Lid")!, in: session.stage)
            == PrimPath(materialPath))
        let looks = session.stage.rootPrims.first { $0.name == "Looks" }
        #expect(looks?.children.count == 1)
    }

    @Test func bindMaterialRejectsNonMaterial() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let error = await callError(server, "bind_material", .object([
            "target": "/Root/Lid",
            "materialPath": "/Root/Box",   // a Mesh, not a Material
        ]))
        #expect(error.contains("Material"))
    }

    @Test func batchBindMaterialAppliesAtomically() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let created = await callOK(server, "create_material", .object(["target": "/Root/Box"]))
        let materialPath = created["materialPath"].stringValue!

        let result = await callOK(server, "batch", .object([
            "label": "share material",
            "ops": .array([
                .object([
                    "tool": "bind_material",
                    "args": .object(["target": "/Root/Lid", "materialPath": .string(materialPath)]),
                ]),
            ]),
        ]))
        #expect(result["verb"].stringValue != nil)
        #expect(MaterialBinding.materialPath(for: PrimPath("/Root/Lid")!, in: session.stage)
            == PrimPath(materialPath))
    }

    @Test func batchBindMaterialRejectsBadTarget() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let error = await callError(server, "batch", .object([
            "ops": .array([
                .object([
                    "tool": "bind_material",
                    "args": .object(["target": "/Root/Lid", "materialPath": "/Root/Box"]),
                ]),
            ]),
        ]))
        #expect(error.contains("cannot bind"))
    }
}

@Suite struct InlineValidationDeltaTests {

    /// The inline validation for a mutation reports counts, but only the NEW
    /// diagnostics it introduced — and info-severity ones are collapsed to
    /// per-rule counts, never the full stage-wide list (#142).
    @Test func inlineValidationIsADeltaNotTheWholeStage() throws {
        let session = Fixtures.session()
        // A neutral mutation that introduces no new diagnostics.
        let outcome = try session.mutate(
            SetActiveCommand(path: PrimPath("/Root/Lid")!, newValue: false, oldValue: true))
        let json = outcome.asJSON()
        let validation = json["validation"]
        // Counts are always present.
        #expect(validation["errors"].doubleValue != nil)
        #expect(validation["info"].doubleValue != nil)
        // The full stage-wide `diagnostics` array is NOT inlined.
        #expect(validation["diagnostics"].arrayValue == nil)
        // Nothing new was introduced, so neither delta key appears.
        #expect(validation["new"].arrayValue == nil)
        #expect(validation["newInfoByRule"].objectValue == nil)
    }

    @Test func newInfoDiagnosticsAreCountedByRule() throws {
        let session = Fixtures.session()
        // Insert a fresh unbound mesh — this introduces new info diagnostics
        // (e.g. mesh.normals / mesh.unbound) relative to the pre-mutation stage.
        let boxFlat = session.stage.prim(at: PrimPath("/Root/Box")!)!.attributes
        let newPrim = Prim(path: PrimPath("/Root/Extra")!, typeName: "Mesh", attributes: boxFlat)
        let outcome = try session.mutate(
            InsertPrimCommand(prim: newPrim, parent: PrimPath("/Root")!, index: 2))
        let validation = outcome.asJSON()["validation"]
        // Any newly-introduced info diagnostics show up as counts, not a list.
        if let byRule = validation["newInfoByRule"].objectValue {
            #expect(byRule.values.allSatisfy { $0.doubleValue != nil })
        }
        #expect(validation["diagnostics"].arrayValue == nil)
    }

    /// Direct coverage of the delta serializer: new error/warning diagnostics are
    /// listed in full under `new`; new info is collapsed under `newInfoByRule`;
    /// diagnostics already present in the baseline are omitted entirely.
    @Test func deltaSerializerSplitsActionableFromInfo() {
        let shared = Diagnostic(ruleID: "pre.existing", severity: .warning, message: "old")
        let baseline = ValidationReport(diagnostics: [shared])
        let after = ValidationReport(diagnostics: [
            shared,                                                              // carried over — omitted
            Diagnostic(ruleID: "mesh.broken", severity: .error, message: "new"), // actionable — listed
            Diagnostic(ruleID: "mesh.normals", severity: .info, message: "a"),   // info — counted
            Diagnostic(ruleID: "mesh.normals", severity: .info, message: "b"),   // info — counted
        ])
        let json = after.inlineDeltaJSON(baseline: baseline)
        let newList = json["new"].arrayValue
        #expect(newList?.count == 1)
        #expect(newList?.first?["rule"].stringValue == "mesh.broken")
        #expect(json["newInfoByRule"]["mesh.normals"].doubleValue == 2)
    }

    @Test func deltaSerializerWithNoBaselineTreatsAllAsNew() {
        let after = ValidationReport(diagnostics: [
            Diagnostic(ruleID: "mesh.broken", severity: .error, message: "x"),
        ])
        let json = after.inlineDeltaJSON(baseline: nil)
        #expect(json["new"].arrayValue?.count == 1)
    }
}
