import ConversionKit
import Foundation
import ScriptingKit
import Testing
import USDBridge
import USDCore
@testable import AgentMCP

/// Targeted tests closing the last uncovered branches: material payloads,
/// multi-root bounds, subtree re-rooting, bridge imports, script edge cases,
/// skinned meshes, and score mesh failures.
@Suite struct CoverageClosureTests {

    @Test func materialBindingsSurfaceEverywhere() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callOK(server, "create_material", ["target": "/Root/Box"])

        // query_scene summary carries the binding.
        let queried = await callOK(server, "query_scene", ["name": "Box"])
        #expect(queried["prims"].arrayValue?.first?["material"].stringValue?.isEmpty == false)

        // get_prim detail lists the relationship.
        let detail = await callOK(server, "get_prim", ["path": "/Root/Box"])
        let rels = detail["relationships"].arrayValue!
        #expect(rels.contains { $0["name"].stringValue == "material:binding" })

        // describe_scene outline carries it.
        let described = await callOK(server, "describe_scene")
        let box = described["hierarchy"].arrayValue!.first!["children"].arrayValue!
            .first { $0["path"].stringValue == "/Root/Box" }!
        #expect(box["material"].stringValue?.isEmpty == false)

        // render_views statsOnly aggregates bound materials.
        let stats = await callOK(server, "render_views", ["paths": ["/Root/Box"], "statsOnly": true])
        #expect(stats["subjects"].arrayValue?.first?["materials"].arrayValue?.isEmpty == false)
    }

    @Test func multiRootBoundsUnion() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callOK(server, "create_mesh", ["name": "Outlier", "shape": "box"])
        _ = await callOK(server, "set_transform", ["path": "/Outlier", "translation": [20, 0, 0]])
        let stats = await callOK(server, "scene_stats")
        let size = stats["bounds"]["size"].doubleArrayValue!
        #expect(size[0] > 15)
    }

    @Test func isolatedRenderReRootsSubtreeWithChildren() async {
        let recorder = Recorder()
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(
                renderer: StubRenderer(recorded: { recorder.append($0) }),
                workDirectory: Fixtures.tempDirectory()))
        _ = await callOK(server, "group_prims", ["paths": ["/Root/Box", "/Root/Lid"], "name": "Body"])
        let rendered = await callOK(server, "render_views",
                                    ["paths": ["/Root/Body"], "views": ["front"]])
        #expect(rendered["images"].arrayValue?.count == 1)
    }

    @Test func groupRejectsNonSiblings() async {
        let server = Fixtures.server(session: Fixtures.session())
        _ = await callOK(server, "create_prim", ["name": "Loose"])
        let message = await callError(server, "group_prims", ["paths": ["/Root/Box", "/Loose"]])
        #expect(message.contains("share a parent"))
    }

    @Test func rotationOnlyTransform() async {
        let server = Fixtures.server(session: Fixtures.session())
        let rotated = await callOK(server, "set_transform",
                                   ["path": "/Root/Box", "rotationEulerDegrees": [0, 45, 0]])
        #expect(rotated["transform"]["rotationEulerDegrees"].doubleArrayValue == [0, 45, 0])
    }

    @Test func skinnedMeshRefusesEditing() async {
        var snapshot = Fixtures.snapshot()
        snapshot.rootPrims[0].children[0].relationships.append(
            Relationship(name: "skel:skeleton", targets: [PrimPath("/Skel")!]))
        let server = Fixtures.server(session: EditSession(snapshot: snapshot))
        let message = await callError(server, "edit_mesh",
                                      ["path": "/Root/Box", "ops": [["op": "delete_faces", "faces": [0]]]])
        #expect(message.contains("unsupported"))
    }

    @Test func scoreReportsMeshFailures() async {
        let server = Fixtures.server(session: Fixtures.session())
        // Corrupt the Lid's topology so gate 2 collects a failure entry.
        _ = await callOK(server, "set_attribute",
                         ["path": "/Root/Lid", "name": "faceVertexIndices", "type": "intArray",
                          "value": [0, 1, 999]])
        _ = await callOK(server, "set_attribute",
                         ["path": "/Root/Lid", "name": "faceVertexCounts", "type": "intArray", "value": [3]])
        let scored = await callOK(server, "score")
        let meshGate = scored["gates"].arrayValue![1]
        #expect(meshGate["pass"].boolValue == false)
        #expect(meshGate["failures"].arrayValue?.first?["path"].stringValue == "/Root/Lid")
    }

    @Test func handlerCrashSurfacesAsInternalToolError() async {
        // Unwritable work directory → render's file write throws a non-ToolError.
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(
                renderer: StubRenderer(recorded: { _ in }),
                workDirectory: URL(fileURLWithPath: "/dev/null/nope")))
        let message = await callError(server, "render_views", ["views": ["front"]])
        #expect(message.contains("internal error"))
    }

    @Test func bridgeImportOfUSDFamilyFiles() async throws {
        struct StubBridge: BridgeExecutor {
            var payload: String
            var fails = false
            func snapshotJSON(forFileAt url: URL) async throws -> Data {
                if fails { throw BridgeError.unreadableFile(path: url.path) }
                return Data(payload.utf8)
            }
            func checkAvailability() async -> BridgeAvailability {
                .available(pythonPath: "/stub")
            }
        }
        let work = Fixtures.tempDirectory()
        let usdaURL = work.appendingPathComponent("widget.usda")
        try "#usda 1.0\n".write(to: usdaURL, atomically: true, encoding: .utf8)

        let session = Fixtures.session()
        session.bridgeExecutor = StubBridge(
            payload: #"{"prims":[{"path":"/Widget","type":"Xform","children":[]}]}"#)
        let server = Fixtures.server(session: session)

        let imported = await callOK(server, "import_asset", ["url": .string(usdaURL.path)])
        #expect(imported["path"].stringValue == "/widget")
        #expect(imported["pipelineLog"].arrayValue?.first?.stringValue?.contains("Python bridge") == true)
        _ = await callOK(server, "get_prim", ["path": "/widget/Widget"])

        // Bridge failure → structured tool error.
        session.bridgeExecutor = StubBridge(payload: "", fails: true)
        let message = await callError(server, "import_asset", ["url": .string(usdaURL.path)])
        #expect(message.contains("bridge import failed"))
    }

    @Test func bridgeImportOfEmptyStageFails() async throws {
        struct EmptyBridge: BridgeExecutor {
            func snapshotJSON(forFileAt url: URL) async throws -> Data {
                Data(#"{"prims":[]}"#.utf8)
            }
            func checkAvailability() async -> BridgeAvailability {
                .available(pythonPath: "/stub")
            }
        }
        let work = Fixtures.tempDirectory()
        let usdaURL = work.appendingPathComponent("empty.usda")
        try "#usda 1.0\n".write(to: usdaURL, atomically: true, encoding: .utf8)
        let session = Fixtures.session()
        session.bridgeExecutor = EmptyBridge()
        let server = Fixtures.server(session: session)
        let message = await callError(server, "import_asset", ["url": .string(usdaURL.path)])
        #expect(message.contains("contains no prims"))
    }

    @Test func geometrylessOBJFailsThePipeline() async {
        let work = Fixtures.tempDirectory()
        let emptyOBJ = work.appendingPathComponent("empty.obj")
        try? "v 0 0 0\nv 1 0 0\nv 0 1 0\n".write(to: emptyOBJ, atomically: true, encoding: .utf8)
        let server = Fixtures.server(session: Fixtures.session())
        let result = await call(server, "import_asset", ["url": .string(emptyOBJ.path)])
        // Vertex-only OBJ: either the importer errors or the pipeline authors
        // nothing — both must surface as a structured tool error.
        #expect(result["isError"].boolValue == true)
    }

    @Test func normalizeRejectsZeroExtent() async {
        var snapshot = Fixtures.snapshot()
        // A degenerate one-point "mesh": bbox exists but has zero extent.
        snapshot.rootPrims[0].children.append(Prim(
            path: PrimPath("/Root/Dot")!, typeName: "Mesh",
            attributes: [
                Attribute(name: "points", value: .float3Array([0, 0, 0])),
                Attribute(name: "faceVertexCounts", value: .intArray([])),
                Attribute(name: "faceVertexIndices", value: .intArray([])),
            ]))
        let server = Fixtures.server(session: EditSession(snapshot: snapshot))
        let message = await callError(server, "normalize_asset", ["path": "/Root/Dot"])
        #expect(message.contains("zero extent"))
    }

    @Test func pipelineHelpersValidateAndSerialize() throws {
        let url = URL(fileURLWithPath: "/tmp/thing.obj")
        // Empty context → structured "no authored stage" failure.
        let empty = ConversionContext(sourceURL: url)
        #expect(throws: ToolError.self) {
            _ = try AssetTools.requireAuthoredStage(empty, url: url)
        }
        var authored = ConversionContext(sourceURL: url)
        authored.authoredStage = Fixtures.snapshot()
        #expect(try AssetTools.requireAuthoredStage(authored, url: url).rootPrims.count == 1)

        let payload = AssetTools.diagnosticsJSON([
            ConversionKit.Diagnostic(severity: .warning, stage: "textures", message: "texture resized")
        ])
        #expect(payload.first?["message"].stringValue == "texture resized")
        #expect(payload.first?["severity"].stringValue?.isEmpty == false)
    }

    @Test func importerFailureIsStructured() async {
        let work = Fixtures.tempDirectory()
        let badGLTF = work.appendingPathComponent("broken.gltf")
        try? Data("{not json".utf8).write(to: badGLTF)
        let server = Fixtures.server(session: Fixtures.session())
        let message = await callError(server, "import_asset", ["url": .string(badGLTF.path)])
        #expect(message.contains("import failed"))
    }

    @Test func scriptProgressAndBadManifest() async {
        /// Executor emitting the harness's `[NN%] message` progress format.
        struct ProgressExecutor: ScriptExecuting {
            var manifestJSON: String
            func execute(
                scriptPath: String, arguments: [String],
                onStandardErrorLine: (@Sendable (String) -> Void)?
            ) async throws -> ScriptProcessResult {
                if arguments == [ScriptRunner.emitManifestFlag] {
                    return ScriptProcessResult(exitCode: 0, standardOutput: manifestJSON, standardError: "")
                }
                onStandardErrorLine?("[50%] halfway there")
                onStandardErrorLine?("plain log line")
                if let flag = arguments.firstIndex(of: "-o"), flag + 1 < arguments.count {
                    try Data("#usda 1.0\n".utf8).write(to: URL(fileURLWithPath: arguments[flag + 1]))
                }
                return ScriptProcessResult(exitCode: 0, standardOutput: "", standardError: "")
            }
        }
        let work = Fixtures.tempDirectory()
        let script = work.appendingPathComponent("s.py")
        try? "x".write(to: script, atomically: true, encoding: .utf8)

        let good = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(
                scriptExecutor: ProgressExecutor(
                    manifestJSON: #"{"name":"s","mutates":true,"args":[]}"#),
                workDirectory: work))
        let result = await callOK(good, "run_script", ["script": .string(script.path)])
        #expect(result["lastProgress"]["fraction"].doubleValue == 0.5)
        #expect(result["lastProgress"]["message"].stringValue == "halfway there")
        #expect(result["log"].arrayValue?.contains(.string("plain log line")) == true)

        let bad = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(
                scriptExecutor: ProgressExecutor(manifestJSON: "{nope"),
                workDirectory: work))
        let message = await callError(bad, "run_script", ["script": .string(script.path)])
        #expect(message.contains("manifest load failed"))
    }
}
