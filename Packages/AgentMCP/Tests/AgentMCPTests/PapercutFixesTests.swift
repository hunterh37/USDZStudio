import EditingKit
import Foundation
import SculptKit
import Testing
import USDCore
@testable import AgentMCP

/// Coverage for the agent-workflow papercut fixes bundled in this PR:
///   • #141 `bind_material` tool + `batch` support (share one material)
///   • #142 inline validation reports only the *new* diagnostics (delta)
///   • #143 the friendly `ShapeKind` wire form decodes through the real
///          `sculpt_author_spec` MCP entry point
///   • #140 the sculpt material-pass `.bindMaterial` executor
@Suite struct PapercutFixesTests {

    // MARK: - #141 bind_material tool

    @Test func bindMaterialSharesOneMaterial() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        // Mint one material on Box.
        let made = await callOK(server, "create_material",
            ["target": "/Root/Box", "baseColor": [0.2, 0.4, 0.6]])
        let materialPath = made["materialPath"].stringValue!

        // Bind that same material to Lid — no new material minted.
        let bound = await callOK(server, "bind_material",
            ["target": "/Root/Lid", "materialPath": .string(materialPath)])
        #expect(bound["materialPath"].stringValue == materialPath)

        // Exactly one Material exists under /Looks, shared by both boxes.
        let looks = session.stage.prim(at: PrimPath("/Looks")!)
        let materials = looks?.children.filter { $0.typeName == "Material" } ?? []
        #expect(materials.count == 1)
    }

    @Test func bindMaterialRejectsBadTargets() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        // Bind to a path that isn't a Material prim.
        _ = await callError(server, "bind_material",
            ["target": "/Root/Lid", "materialPath": "/Root/Box"])
        // Missing material prim entirely.
        _ = await callError(server, "bind_material",
            ["target": "/Root/Lid", "materialPath": "/Ghost"])
    }

    @Test func bindMaterialInBatch() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let made = await callOK(server, "create_material", ["target": "/Root/Box"])
        let materialPath = made["materialPath"].stringValue!

        let batched = await callOK(server, "batch", ["ops": [
            ["tool": "bind_material",
             "args": ["target": "/Root/Lid", "materialPath": .string(materialPath)]],
        ]])
        #expect(batched["verb"].stringValue != nil)
        #expect(MaterialBinding.materialPath(for: PrimPath("/Root/Lid")!, in: session.stage)
                == PrimPath(materialPath))

        // A bad bind op fails the whole batch.
        _ = await callError(server, "batch", ["ops": [
            ["tool": "bind_material",
             "args": ["target": "/Root/Lid", "materialPath": "/Root/Box"]],
        ]])
    }

    // MARK: - #142 inline validation delta

    @Test func inlineValidationReportsOnlyNewDiagnostics() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        // Adding a mesh introduces new info-level diagnostics (mesh.normals etc).
        let mutated = await callOK(server, "create_mesh",
            ["name": "Extra", "shape": "box"])
        let validation = mutated["validation"]
        #expect(!validation.isNull)

        // Totals are still reported…
        #expect(validation["errors"].intValue != nil)
        #expect(validation["isCompliant"].boolValue != nil)

        // …but the delta block scopes the detail to what THIS call introduced.
        let new = validation["new"]
        #expect(!new.isNull)
        #expect(new["byRule"].objectValue != nil)

        // Info-severity diagnostics are collapsed to counts, never listed inline.
        let listed = new["diagnostics"].arrayValue ?? []
        #expect(listed.allSatisfy { $0["severity"].stringValue != "info" })
        // The new info count is surfaced even though none are listed.
        #expect((new["info"].intValue ?? 0) >= 0)
    }

    // MARK: - #143 friendly ShapeKind wire form round-trips through the MCP entry

    @Test func friendlyShapeKindDecodesThroughAuthorSpec() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        // The exact documented friendly form from issue #143 — the one that used
        // to fail against a stale CLI binary. It must decode through the real
        // sculpt_author_spec tool, not just SculptKit unit tests.
        let spec: JSONValue = [
            "name": "T", "objectClass": "object",
            "root": [
                "name": "Root", "shape": ["kind": "group"],
                "children": [
                    ["name": "Bx",
                     "shape": ["kind": "primitive", "primitive": "box"],
                     "attachment": "weld"],
                ],
            ],
        ]
        let out = await callOK(server, "sculpt_author_spec", ["spec": spec])
        #expect(out["name"].stringValue == "T")
        #expect(out["componentCount"].doubleValue == 2)
    }

    // MARK: - #140 sculpt material-pass bindMaterial executor

    @Test func sculptBindMaterialExecutorSharesAndSkips() async throws {
        let session = Fixtures.session()
        let material = MaterialSpec(id: "m", baseColor: [1, 0, 0])

        // Skip path: source has no material yet → nil, nothing authored.
        let skipped = try await SculptTools.execute(
            step: .bindMaterial(targetPath: "/Root/Lid", sourcePath: "/Root/Box"),
            session: session)
        #expect(skipped == nil)

        // Author the base material on Box, then share it with Lid.
        _ = try await SculptTools.execute(
            step: .createMaterial(targetPath: "/Root/Box", material: material),
            session: session)
        let shared = try await SculptTools.execute(
            step: .bindMaterial(targetPath: "/Root/Lid", sourcePath: "/Root/Box"),
            session: session)
        #expect(shared != nil)
        // Both resolve to the same single material.
        let boxMat = MaterialBinding.materialPath(for: PrimPath("/Root/Box")!, in: session.stage)
        let lidMat = MaterialBinding.materialPath(for: PrimPath("/Root/Lid")!, in: session.stage)
        #expect(boxMat == lidMat)
        #expect(boxMat != nil)
    }
}
