import Foundation
import Testing
import USDCore
@testable import AgentMCP

@Suite struct ReadToolTests {

    @Test func querySceneWithFilters() async {
        let server = Fixtures.server(session: Fixtures.session())
        let all = await callOK(server, "query_scene")
        #expect(all["count"].intValue == 3)
        let meshes = await callOK(server, "query_scene", ["type": "Mesh"])
        #expect(meshes["count"].intValue == 2)
        let named = await callOK(server, "query_scene", ["name": "Lid"])
        #expect(named["prims"].arrayValue?.first?["path"].stringValue == "/Root/Lid")
        #expect(named["prims"].arrayValue?.first?["bbox"]["size"].doubleArrayValue?.count == 3)
        let none = await callOK(server, "query_scene", ["name": "Ghost"])
        #expect(none["count"].intValue == 0)
    }

    @Test func getPrimDetail() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let detail = await callOK(server, "get_prim", ["path": "/Root/Box"])
        #expect(detail["type"].stringValue == "Mesh")
        #expect(detail["primId"].stringValue?.hasPrefix("prim-") == true)
        let attrs = detail["attributes"].arrayValue!
        #expect(attrs.contains { $0["name"].stringValue == "points" })
        // Big arrays elided to count+preview.
        let points = attrs.first { $0["name"].stringValue == "points" }!
        #expect(points["value"]["count"].intValue == 24)
        #expect(detail["worldMatrix"].arrayValue?.count == 16)
        _ = await callError(server, "get_prim", ["path": "/Nope"])
    }

    @Test func variantsListing() async throws {
        var snapshot = Fixtures.snapshot()
        snapshot.rootPrims[0].variantSets = [
            VariantSet(name: "look", variants: ["red", "blue"], selection: "red")
        ]
        let server = Fixtures.server(session: EditSession(snapshot: snapshot))
        let result = await callOK(server, "list_variants", ["path": "/Root"])
        let set = result["variantSets"].arrayValue!.first!
        #expect(set["name"].stringValue == "look")
        #expect(set["selection"].stringValue == "red")
        let empty = await callOK(server, "list_variants", ["path": "/Root/Box"])
        #expect(empty["variantSets"].arrayValue?.isEmpty == true)
    }

    @Test func describeSceneOutlineAndBudget() async {
        let server = Fixtures.server(session: Fixtures.session())
        let described = await callOK(server, "describe_scene")
        #expect(described["stats"]["prims"].intValue == 3)
        #expect(described["strictness"].stringValue == "warn")
        let hierarchy = described["hierarchy"].arrayValue!.first!
        #expect(hierarchy["children"].arrayValue?.count == 2)
        // Depth 1 elides children.
        let shallow = await callOK(server, "describe_scene", ["maxDepth": 1])
        let top = shallow["hierarchy"].arrayValue!.first!
        #expect(top["childrenElided"].intValue == 2)
    }

    @Test func attributeJSONVariants() {
        #expect(ReadTools.attributeJSON(.bool(true)).boolValue == true)
        #expect(ReadTools.attributeJSON(.int(4)).intValue == 4)
        #expect(ReadTools.attributeJSON(.double(2.5)).doubleValue == 2.5)
        #expect(ReadTools.attributeJSON(.string("s")).stringValue == "s")
        #expect(ReadTools.attributeJSON(.token("t")).stringValue == "t")
        #expect(ReadTools.attributeJSON(.asset("a.png")).stringValue == "a.png")
        #expect(ReadTools.attributeJSON(.vector([1, 2, 3])).doubleArrayValue == [1, 2, 3])
        #expect(ReadTools.attributeJSON(.intArray([1, 2])).doubleArrayValue == [1, 2])
        #expect(ReadTools.attributeJSON(.stringArray(["x"])).stringArrayValue == ["x"])
        #expect(ReadTools.attributeJSON(.tokenArray(["y"])).stringArrayValue == ["y"])
        #expect(ReadTools.attributeJSON(.unsupported(typeName: "weird"))["unsupported"].stringValue == "weird")
        let big = ReadTools.attributeJSON(.doubleArray(Array(repeating: 1, count: 40)))
        #expect(big["count"].intValue == 40)
        #expect(big["preview"].arrayValue?.count == 6)
    }
}

@Suite struct MutateToolTests {

    @Test func createRenameReparentDuplicateGroupRemove() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        let created = await callOK(server, "create_prim", ["parent": "/Root", "name": "Props", "type": "Scope"])
        #expect(created["path"].stringValue == "/Root/Props")
        #expect(created["diff"]["added"].arrayValue?.count == 1)
        #expect(created["undoToken"].intValue == 1)
        let propsID = created["primIds"]["/Root/Props"].stringValue!

        // Root-level create + name collision + bad name.
        _ = await callOK(server, "create_prim", ["name": "Extra"])
        _ = await callError(server, "create_prim", ["parent": "/Root", "name": "Props"])
        _ = await callError(server, "create_prim", ["parent": "/Root", "name": "bad name!"])
        _ = await callError(server, "create_prim", ["parent": "/Nope", "name": "X"])

        // Rename: primId follows.
        let renamed = await callOK(server, "rename_prim", ["path": .string(propsID), "name": "Stuff"])
        #expect(renamed["verb"].stringValue?.contains("Rename") == true)
        let detail = await callOK(server, "get_prim", ["path": .string(propsID)])
        #expect(detail["path"].stringValue == "/Root/Stuff")
        _ = await callError(server, "rename_prim", ["path": "/Root/Stuff", "name": ""])

        // Reparent to root; primId follows.
        _ = await callOK(server, "reparent_prim", ["path": .string(propsID)])
        let moved = await callOK(server, "get_prim", ["path": .string(propsID)])
        #expect(moved["path"].stringValue == "/Stuff")
        // Reparent under a Mesh child (valid target).
        _ = await callOK(server, "reparent_prim", ["path": .string(propsID), "newParent": "/Root"])
        // Cycle rejected.
        _ = await callError(server, "reparent_prim", ["path": "/Root", "newParent": "/Root/Stuff"])

        // Duplicate.
        let dupe = await callOK(server, "duplicate_prim", ["path": "/Root/Box"])
        #expect(dupe["path"].stringValue?.hasPrefix("/Root/Box") == true)

        // Group the two meshes.
        let grouped = await callOK(server, "group_prims",
                                   ["paths": ["/Root/Box", "/Root/Lid"], "name": "Body"])
        #expect(grouped["path"].stringValue == "/Root/Body")
        _ = await callOK(server, "get_prim", ["path": "/Root/Body/Box"])
        _ = await callError(server, "group_prims", ["paths": []])
        _ = await callError(server, "group_prims", ["paths": ["/Root/Body/Box", "/Stuff"]])

        // Remove: id dies permanently.
        _ = await callOK(server, "remove_prim", ["path": .string(propsID)])
        _ = await callError(server, "get_prim", ["path": .string(propsID)])
    }

    @Test func createMeshShapes() async {
        let server = Fixtures.server(session: Fixtures.session())
        for shape in ["plane", "box", "cylinder", "cone", "sphere"] {
            let result = await callOK(server, "create_mesh",
                                      ["name": .string("S_\(shape)"), "shape": .string(shape)])
            let check = await callOK(server, "check_mesh", ["path": result["path"]])
            #expect(check["pass"].boolValue == true, "\(shape) not healthy")
        }
        _ = await callError(server, "create_mesh", ["name": "X", "shape": "torus"])
        _ = await callError(server, "create_mesh", ["name": "X", "shape": "box", "width": -1])
        _ = await callError(server, "create_mesh", ["name": "X", "shape": "cone", "segments": 2])

        // #97: a plain create_mesh authors subdivisionScheme = "none" (crisp polys),
        // and `smooth: true` opts into a Catmull-Clark subdivision surface.
        func subdivScheme(_ prim: JSONValue) -> String? {
            prim["attributes"].arrayValue?
                .first { $0["name"].stringValue == "subdivisionScheme" }?["value"].stringValue
        }
        let crisp = await callOK(server, "create_mesh", ["name": "Crisp", "shape": "box"])
        let crispPrim = await callOK(server, "get_prim", ["path": crisp["path"]])
        #expect(subdivScheme(crispPrim) == "none")

        let smooth = await callOK(server, "create_mesh",
                                  ["name": "Smooth", "shape": "box", "smooth": .bool(true)])
        let smoothPrim = await callOK(server, "get_prim", ["path": smooth["path"]])
        #expect(subdivScheme(smoothPrim) == "catmullClark")
    }

    @Test func setActiveVariantAttributeAndRemoveAttribute() async {
        var snapshot = Fixtures.snapshot()
        snapshot.rootPrims[0].variantSets = [
            VariantSet(name: "look", variants: ["red", "blue"], selection: nil)
        ]
        let server = Fixtures.server(session: EditSession(snapshot: snapshot))

        let deactivated = await callOK(server, "set_active", ["path": "/Root/Lid", "active": false])
        #expect(deactivated["verb"].stringValue?.contains("Disable") == true)
        _ = await callError(server, "set_active", ["path": "/Root/Lid"])

        _ = await callOK(server, "set_variant", ["path": "/Root", "set": "look", "selection": "blue"])
        _ = await callError(server, "set_variant", ["path": "/Root", "set": "look", "selection": "green"])
        _ = await callError(server, "set_variant", ["path": "/Root", "set": "nope", "selection": "x"])
        _ = await callError(server, "set_variant", ["path": "/Root"])

        let attrSet = await callOK(server, "set_attribute",
                                   ["path": "/Root", "name": "doc", "type": "string", "value": "hello"])
        #expect(attrSet["diff"]["changedAttributes"]["/Root"].stringArrayValue == ["doc"])
        _ = await callError(server, "set_attribute", ["path": "/Root", "name": "x", "type": "quat", "value": 1])
        _ = await callError(server, "set_attribute", ["path": "/Root", "type": "int", "value": 1])

        _ = await callOK(server, "remove_attribute", ["path": "/Root", "name": "doc"])
        _ = await callError(server, "remove_attribute", ["path": "/Root", "name": "doc"])
    }

    @Test func attributeValueDecodingMatrix() throws {
        typealias M = MutateTools
        #expect(try M.attributeValue(type: "bool", json: .bool(true)) == .bool(true))
        #expect(try M.attributeValue(type: "int", json: 3) == .int(3))
        #expect(try M.attributeValue(type: "double", json: 2.5) == .double(2.5))
        #expect(try M.attributeValue(type: "string", json: "s") == .string("s"))
        #expect(try M.attributeValue(type: "token", json: "t") == .token("t"))
        #expect(try M.attributeValue(type: "asset", json: "a") == .asset("a"))
        #expect(try M.attributeValue(type: "vector", json: [1, 2, 3]) == .vector([1, 2, 3]))
        #expect(try M.attributeValue(type: "matrix4", json: .array(Array(repeating: 0, count: 16))) != nil)
        #expect(try M.attributeValue(type: "doubleArray", json: [1]) == .doubleArray([1]))
        #expect(try M.attributeValue(type: "float3Array", json: [1, 2, 3]) == .float3Array([1, 2, 3]))
        #expect(try M.attributeValue(type: "intArray", json: [1]) == .intArray([1]))
        #expect(try M.attributeValue(type: "stringArray", json: ["a"]) == .stringArray(["a"]))
        #expect(try M.attributeValue(type: "tokenArray", json: ["a"]) == .tokenArray(["a"]))

        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "bool", json: 1) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "int", json: 1.5) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "double", json: "x") }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "string", json: 1) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "token", json: 1) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "asset", json: 1) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "vector", json: [1]) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "vector", json: "x") }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "float3Array", json: [1, 2]) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "intArray", json: [1.5]) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "stringArray", json: [1]) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "tokenArray", json: [1]) }
        #expect(throws: ToolError.self) { _ = try M.attributeValue(type: "mystery", json: 1) }
    }

    @Test func setTransformAbsoluteAndValidation() async {
        let server = Fixtures.server(session: Fixtures.session())
        let moved = await callOK(server, "set_transform",
                                 ["path": "/Root/Box", "translation": [1, 2, 3], "scale": [2, 2, 2]])
        #expect(moved["transform"]["translation"].doubleArrayValue == [1, 2, 3])
        _ = await callError(server, "set_transform", ["path": "/Root/Box", "translation": [1]])
        _ = await callError(server, "set_transform", ["path": "/Root/Box", "rotationEulerDegrees": [1]])
        _ = await callError(server, "set_transform", ["path": "/Root/Box", "scale": [0, 1, 1]])
    }

    @Test func setTransformRelativeToRules() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        let onTop = await callOK(server, "set_transform", [
            "path": "/Root/Lid",
            "relativeTo": ["anchor": "/Root/Box", "rule": "on_top", "gap": 0.1],
        ])
        _ = onTop
        let lid = GeometryProbe.worldBBox(of: PrimPath("/Root/Lid")!, in: session.stage)!
        let box = GeometryProbe.worldBBox(of: PrimPath("/Root/Box")!, in: session.stage)!
        #expect(abs(lid.min[1] - (box.max[1] + 0.1)) < 1e-9)
        #expect(abs(lid.center[0] - box.center[0]) < 1e-9)

        for rule in ["below", "left_of", "right_of", "in_front_of", "behind", "inside_center"] {
            _ = await callOK(server, "set_transform", [
                "path": "/Root/Lid",
                "relativeTo": ["anchor": "/Root/Box", "rule": .string(rule)],
            ])
        }
        let inside = GeometryProbe.worldBBox(of: PrimPath("/Root/Lid")!, in: session.stage)!
        #expect(abs(inside.center[1] - box.center[1]) < 1e-9)

        // keep-align preserves off-axis position.
        _ = await callOK(server, "set_transform", [
            "path": "/Root/Lid", "translation": [5, 0, 0],
        ])
        _ = await callOK(server, "set_transform", [
            "path": "/Root/Lid",
            "relativeTo": ["anchor": "/Root/Box", "rule": "on_top", "align": "keep"],
        ])
        let kept = GeometryProbe.worldBBox(of: PrimPath("/Root/Lid")!, in: session.stage)!
        #expect(abs(kept.center[0] - 5) < 1e-9)

        // Errors: unknown rule / align, missing rule, anchor without geometry, self-anchor.
        _ = await callError(server, "set_transform",
                            ["path": "/Root/Lid", "relativeTo": ["anchor": "/Root/Box", "rule": "orbiting"]])
        _ = await callError(server, "set_transform",
                            ["path": "/Root/Lid", "relativeTo": ["anchor": "/Root/Box"]])
        _ = await callError(server, "set_transform",
                            ["path": "/Root/Lid",
                             "relativeTo": ["anchor": "/Root/Box", "rule": "on_top", "align": "sideways"]])
        _ = await callError(server, "set_transform",
                            ["path": "/Root/Lid", "relativeTo": ["anchor": "/Root/Lid", "rule": "on_top"]])
        _ = await callOK(server, "create_prim", ["name": "Empty"])
        _ = await callError(server, "set_transform",
                            ["path": "/Root/Lid", "relativeTo": ["anchor": "/Empty", "rule": "on_top"]])
        _ = await callError(server, "set_transform",
                            ["path": "/Empty", "relativeTo": ["anchor": "/Root/Box", "rule": "on_top"]])
    }

    @Test func createMaterial() async {
        let server = Fixtures.server(session: Fixtures.session())
        let made = await callOK(server, "create_material",
                                ["target": "/Root/Box", "baseColor": [0.8, 0.1, 0.1]])
        #expect(made["materialPath"].stringValue?.isEmpty == false)
        _ = await callError(server, "create_material", ["target": "/Root/Box", "baseColor": [2, 0, 0]])
        _ = await callError(server, "create_material", ["target": "/Root/Box", "baseColor": [1, 0]])
    }

    @Test func editMeshChainAndErrors() async {
        let server = Fixtures.server(session: Fixtures.session())
        let extruded = await callOK(server, "edit_mesh", [
            "path": "/Root/Box",
            "ops": [
                ["op": "inset_faces", "faces": [0], "fraction": 0.25],
                ["op": "extrude_faces", "distance": 0.5],  // reuses inset's result selection
            ],
        ])
        let deltas = extruded["topologyDeltas"].arrayValue!
        #expect(deltas.count == 2)
        #expect(deltas[1]["faces"].intValue ?? 0 > 0)
        #expect(extruded["verb"].stringValue?.isEmpty == false)

        let deleted = await callOK(server, "edit_mesh", [
            "path": "/Root/Lid",
            "ops": [["op": "delete_faces", "faces": [0]]],
        ])
        #expect(deleted["topologyDeltas"].arrayValue?.first?["faces"].intValue == -1)

        _ = await callError(server, "edit_mesh", ["path": "/Root/Box", "ops": []])
        _ = await callError(server, "edit_mesh", ["path": "/Root", "ops": [["op": "delete_faces", "faces": [0]]]])
        _ = await callError(server, "edit_mesh",
                            ["path": "/Root/Box", "ops": [["op": "extrude_faces", "distance": 1]]])
        _ = await callError(server, "edit_mesh",
                            ["path": "/Root/Box", "ops": [["op": "twist", "faces": [0]]]])
        _ = await callError(server, "edit_mesh",
                            ["path": "/Root/Box", "ops": [["op": "extrude_faces", "faces": [0]]]])
        _ = await callError(server, "edit_mesh",
                            ["path": "/Root/Box", "ops": [["op": "inset_faces", "faces": [0], "fraction": 2]]])
        _ = await callError(server, "edit_mesh",
                            ["path": "/Root/Box", "ops": [["op": "delete_faces", "faces": [99]]]])

        // #69: whole-mesh mirror + solidify ops over the MCP mutate path.
        let mirrored = await callOK(server, "edit_mesh", [
            "path": "/Root/Box",
            "ops": [["op": "mirror", "axis": "y", "coordinate": 5]],  // plane clear of the mesh
        ])
        #expect(mirrored["topologyDeltas"].arrayValue?.count == 1)

        let solidified = await callOK(server, "edit_mesh", [
            "path": "/Root/Lid",
            "ops": [["op": "solidify", "thickness": 0.05]],
        ])
        #expect(solidified["topologyDeltas"].arrayValue?.first?["faces"].intValue ?? 0 > 0)

        // mirror defaults axis to x when omitted (plane clear of the mesh).
        _ = await callOK(server, "edit_mesh",
                         ["path": "/Root/Box", "ops": [["op": "mirror", "coordinate": 5]]])
        // Error paths: bad axis, missing/zero thickness.
        _ = await callError(server, "edit_mesh",
                            ["path": "/Root/Box", "ops": [["op": "mirror", "axis": "w"]]])
        _ = await callError(server, "edit_mesh",
                            ["path": "/Root/Box", "ops": [["op": "solidify"]]])
    }

    @Test func batchIsOneUndoStep() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let result = await callOK(server, "batch", [
            "label": "prep",
            "ops": [
                ["tool": "set_attribute",
                 "args": ["path": "/Root", "name": "doc", "type": "string", "value": "d"]],
                ["tool": "set_active", "args": ["path": "/Root/Lid", "active": false]],
                ["tool": "rename_prim", "args": ["path": "/Root/Box", "name": "Crate"]],
            ],
        ])
        #expect(result["verb"].stringValue == "prep")
        #expect(session.stack.undoCount == 1)
        _ = await callOK(server, "get_prim", ["path": "/Root/Crate"])
        let undo = await callOK(server, "undo")
        #expect(undo["undone"].stringValue == "prep")
        _ = await callOK(server, "get_prim", ["path": "/Root/Box"])

        _ = await callError(server, "batch", ["ops": []])
        _ = await callError(server, "batch", ["ops": [["tool": "explode", "args": [:]]]])
        _ = await callError(server, "batch",
                            ["ops": [["tool": "set_attribute", "args": ["path": "/Root"]]]])
        _ = await callError(server, "batch",
                            ["ops": [["tool": "set_active", "args": ["path": "/Root"]]]])
        _ = await callError(server, "batch",
                            ["ops": [["tool": "rename_prim", "args": ["path": "/Root", "name": "!"]]]])
        // Batch remove works and invalidates ids.
        _ = await callOK(server, "batch", ["ops": [["tool": "remove_prim", "args": ["path": "/Root/Lid"]]]])
        _ = await callError(server, "get_prim", ["path": "/Root/Lid"])
    }
}
