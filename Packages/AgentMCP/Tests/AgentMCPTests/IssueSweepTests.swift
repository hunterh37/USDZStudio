import Foundation
import Testing
import EditingKit
import MeshKit
import SculptKit
import USDCore
@testable import AgentMCP

/// Tests for the #155–#162 issue sweep: capability handshake, open_in_app,
/// spec-aware spatial gate, joint sign auto-correction, authored normals,
/// rebuild hygiene, and shared spec-named materials.
@Suite struct IssueSweepTests {

    // MARK: - capabilities (#155)

    @Test func capabilitiesReportsSchemaAndOpSet() async {
        let server = Fixtures.server(session: Fixtures.session())
        let caps = await callOK(server, "capabilities")
        #expect(caps["schemaRevision"].doubleValue == Double(AppTools.schemaRevision))
        #expect(caps["stageAttachment"].stringValue == "headless")
        let kinds = caps["sculpt"]["refinementKinds"].stringArrayValue ?? []
        #expect(kinds == ["inset", "subdivide", "taper", "bevel", "extrude"])
        #expect(caps["sculpt"]["shapeKindWireForm"].stringValue?.contains("primitive") == true)
        #expect(caps["toolGroups"].stringArrayValue?.contains("sculpt") == true)
    }

    @Test func supportedKindNamesMatchesDecodableKinds() throws {
        // Every advertised kind decodes (the handshake can't advertise ops the
        // decoder rejects).
        for kind in MeshRefinement.supportedKindNames {
            let json: String
            switch kind {
            case "inset": json = #"{"kind":"inset","fraction":0.3,"depth":0.1}"#
            case "subdivide": json = #"{"kind":"subdivide","levels":1}"#
            case "taper": json = #"{"kind":"taper","axis":"y","scale":0.5}"#
            case "bevel": json = #"{"kind":"bevel","width":0.05,"angleDegrees":30}"#
            case "extrude": json = #"{"kind":"extrude","direction":"+z","distance":0.2}"#
            default: json = "{}"
            }
            #expect(throws: Never.self, "kind \(kind) must decode") {
                _ = try JSONDecoder().decode(MeshRefinement.self, from: Data(json.utf8))
            }
        }
    }

    // MARK: - open_in_app (#162)

    /// Captures what the injected opener was asked to open.
    final class OpenRecorder: @unchecked Sendable {
        var urls: [URL] = []
        var apps: [String?] = []
    }

    static func serverWithOpener(
        _ recorder: OpenRecorder, session: EditSession? = nil, failing: Bool = false
    ) -> MCPServer {
        let session = session ?? Fixtures.session()
        let configuration = AgentMCPServer.Configuration(
            workDirectory: Fixtures.tempDirectory(),
            appOpener: { url, app in
                recorder.urls.append(url)
                recorder.apps.append(app)
                if failing { throw ToolError.failed("no GUI available") }
            })
        return AgentMCPServer.make(session: session, configuration: configuration)
    }

    @Test func openInAppSavesSnapshotAndOpens() async throws {
        let recorder = OpenRecorder()
        let server = Self.serverWithOpener(recorder)
        let result = await callOK(server, "open_in_app")
        let opened = try #require(result["opened"].stringValue)
        // No bridge executor on the test session → usda snapshot.
        #expect(opened.hasSuffix("live-preview.usda"))
        #expect(FileManager.default.fileExists(atPath: opened))
        #expect(recorder.urls.map(\.path) == [opened])
        #expect(recorder.apps == [nil])
        #expect(result["stageAttachment"].stringValue == "headless")
        #expect(result["note"].stringValue?.contains("snapshot") == true)
    }

    @Test func openInAppHonorsExplicitURLAndApp() async throws {
        let recorder = OpenRecorder()
        let server = Self.serverWithOpener(recorder)
        let destination = Fixtures.tempDirectory().appendingPathComponent("reveal.usda")
        let result = await callOK(server, "open_in_app",
            ["url": .string(destination.path), "app": "USDZ Studio"])
        #expect(result["opened"].stringValue == destination.path)
        #expect(recorder.apps == ["USDZ Studio"])
    }

    @Test func openInAppSurfacesOpenerFailure() async {
        let recorder = OpenRecorder()
        let server = Self.serverWithOpener(recorder, failing: true)
        let message = await callError(server, "open_in_app")
        #expect(message.contains("no GUI available"))
    }

    @Test func systemOpenerFailsOnMissingFile() {
        // `/usr/bin/open` exits non-zero for a path that doesn't exist — this
        // exercises the real launcher end-to-end without opening any UI.
        #expect(throws: (any Error).self) {
            try AppTools.systemOpener(
                URL(fileURLWithPath: "/nonexistent/agentmcp-\(UUID().uuidString).usda"), nil)
        }
    }

    // MARK: - Spec-aware spatial gate (#161)

    /// Two overlapping sibling unit boxes named to match spec components.
    static func overlappingSession() -> EditSession {
        let flat = MeshIO.flat(from: try! Primitives.box())
        let a = Prim(path: PrimPath("/Obj/Body")!, typeName: "Mesh",
                     attributes: GeometryProbe.meshAttributes(from: flat))
        let b = Prim(path: PrimPath("/Obj/Window")!, typeName: "Mesh",
                     attributes: GeometryProbe.meshAttributes(from: flat))
        let root = Prim(path: PrimPath("/Obj")!, typeName: "Xform", children: [a, b])
        let snapshot = StageSnapshot(
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: "Obj"),
            rootPrims: [root])
        return EditSession(snapshot: snapshot)
    }

    static func weldedSpec() -> ObjectSculptSpec {
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .root)
        let window = ComponentNode(name: "Window", shape: .primitive(.box), attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body, window])
        return ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
    }

    @Test func spatialGateExemptsDeclaredWelds() throws {
        let session = Self.overlappingSession()
        // Without a spec: the overlap is an unintended interpenetration.
        let bare = VerifyTools.score(session: session, args: .object([:]))
        let bareSpatial = try #require(bare["gates"].arrayValue?.first { $0["gate"].stringValue == "spatial" })
        #expect(bareSpatial["pass"].boolValue == false)
        #expect(bareSpatial["interpenetrations"].arrayValue?.count == 1)

        // With the spec declaring Window welded to the body: declared contact.
        let scored = VerifyTools.score(session: session, args: .object([:]), spec: Self.weldedSpec())
        let spatial = try #require(scored["gates"].arrayValue?.first { $0["gate"].stringValue == "spatial" })
        #expect(spatial["pass"].boolValue == true)
        #expect(spatial["interpenetrations"].arrayValue?.isEmpty == true)
        #expect(spatial["declaredContactCount"].doubleValue == 1)
        #expect(spatial["declaredContacts"].arrayValue?.count == 1)
    }

    @Test func spatialGateStillFlagsUndeclaredOverlaps() throws {
        let session = Self.overlappingSession()
        // A spec that knows both components but declares no contact for either
        // (free): the overlap stays a failure.
        let body = ComponentNode(name: "Body", shape: .primitive(.box), attachment: .free)
        let window = ComponentNode(name: "Window", shape: .primitive(.box), attachment: .free)
        let root = ComponentNode(name: "Obj", shape: .group, children: [body, window])
        let spec = ObjectSculptSpec(name: "Obj", objectClass: .object, root: root)
        let scored = VerifyTools.score(session: session, args: .object([:]), spec: spec)
        let spatial = try #require(scored["gates"].arrayValue?.first { $0["gate"].stringValue == "spatial" })
        #expect(spatial["pass"].boolValue == false)
        #expect(spatial["declaredContactCount"].doubleValue == 0)
    }

    @Test func specComponentNameHelpers() {
        let spec = Self.weldedSpec()
        #expect(spec.allComponentNames == ["Obj", "Body", "Window"])
        // Obj (group, no attachment) is not a contact declarer; Body (root) and
        // Window (weld) are.
        #expect(spec.declaredContactComponentNames == ["Body", "Window"])
    }

    // MARK: - Authored normals (#159)

    @Test func meshAttributesIncludeSmoothNormals() {
        let flat = MeshIO.flat(from: try! Primitives.box())
        let attributes = GeometryProbe.meshAttributes(from: flat)
        let normals = attributes.first { $0.name == "normals" }
        #expect(normals != nil)
        if case .float3Array(let values)? = normals?.value {
            #expect(values.count == flat.points.count * 3)
        } else {
            Issue.record("normals should be a float3Array")
        }
        #expect(normals?.metadata["interpolation"] == "\"vertex\"")
    }

    @Test func meshAttributesSkipNormalsForBrokenTopology() {
        // counts/indices mismatch → VertexNormals declines → no normals attr.
        let broken = FlatMesh(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            faceVertexCounts: [4], faceVertexIndices: [0, 1, 2],
            hasSkeletalBinding: false)
        let attributes = GeometryProbe.meshAttributes(from: broken)
        #expect(!attributes.contains { $0.name == "normals" })
    }

    // MARK: - create_joint openTowards (#160)

    @Test func openTowardsKeepsCorrectSign() async throws {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        // Lid centred at (0,3,0); hinge about +Z through its left edge. A
        // positive angle already swings the centre upward (right-hand rule),
        // toward a hint high above — no flip, no note.
        let result = await callOK(server, "create_joint", [
            "target": "/Root/Lid", "axis": [0, 0, 1], "pivot": [-0.5, 3, 0],
            "openValue": 90, "openTowards": [0, 10, 0],
        ])
        #expect(result["note"].stringValue == nil)
        #expect(result["pivotPath"].stringValue != nil)
    }

    @Test func openTowardsFlipsWrongSign() async throws {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        // Same hinge, but the hint is far BELOW: +90 would swing up, so the
        // sign must flip and say so.
        let result = await callOK(server, "create_joint", [
            "target": "/Root/Lid", "axis": [0, 0, 1], "pivot": [-0.5, 3, 0],
            "openValue": 90, "openTowards": [0, -10, 0],
        ])
        #expect(result["note"].stringValue?.contains("flipped") == true)
        #expect(result["note"].stringValue?.contains("-90") == true)
    }

    @Test func openTowardsRejectsMalformedVector() async {
        let server = Fixtures.server(session: Fixtures.session())
        let message = await callError(server, "create_joint", [
            "target": "/Root/Lid", "axis": [0, 0, 1], "pivot": [-0.5, 3, 0],
            "openValue": 90, "openTowards": [0, 1],
        ])
        #expect(message.contains("openTowards"))
    }

    @Test func openSignPrismaticAndDegenerateCases() throws {
        let session = Fixtures.session()
        let lid = try session.resolve(.object(["path": .string("/Root/Lid")]))

        // Prismatic: hint along +Y keeps the positive slide, -Y flips it.
        #expect(JointTools.openSign(
            target: lid, kind: .prismatic, axis: [0, 1, 0], pivot: [0, 3, 0],
            openValue: 2, towards: [0, 30, 0], session: session) == 2)
        #expect(JointTools.openSign(
            target: lid, kind: .prismatic, axis: [0, 1, 0], pivot: [0, 3, 0],
            openValue: 2, towards: [0, -30, 0], session: session) == -2)

        // Degenerate axis → no signal.
        #expect(JointTools.openSign(
            target: lid, kind: .revolute, axis: [0, 0, 0], pivot: [0, 3, 0],
            openValue: 45, towards: [0, 10, 0], session: session) == nil)

        // Equidistant hint (on the symmetry plane) → no signal.
        #expect(JointTools.openSign(
            target: lid, kind: .prismatic, axis: [0, 1, 0], pivot: [0, 3, 0],
            openValue: 2, towards: [10, 3, 0], session: session) == nil)

        // No geometry under the target → no bbox → no signal.
        let root = try session.resolve(.object(["path": .string("/Root")]))
        _ = root // /Root has geometry; use a fresh empty group instead.
        let empty = EditSession(snapshot: StageSnapshot(
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: nil),
            rootPrims: [Prim(path: PrimPath("/G")!, typeName: "Xform"),
                        Prim(path: PrimPath("/G2")!, typeName: "Xform",
                             children: [Prim(path: PrimPath("/G2/P")!, typeName: "Xform")])]))
        let bare = try empty.resolve(.object(["path": .string("/G2/P")]))
        #expect(JointTools.openSign(
            target: bare, kind: .revolute, axis: [0, 0, 1], pivot: [0, 0, 0],
            openValue: 45, towards: [0, 10, 0], session: empty) == nil)
    }

    // MARK: - Rebuild hygiene (#158)

    @Test func authoringReplacementSpecCleansPreviousBuild() async {
        let session = Fixtures.emptySession()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.weldedSpec())])
        _ = await callOK(server, "sculpt_build_pass")
        #expect(session.stage.prim(at: PrimPath("/Obj")!) != nil)

        // Re-author: previous root removed, build pass runs clean.
        let replaced = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.weldedSpec())])
        #expect(replaced["cleaned"].stringArrayValue == ["/Obj"])
        #expect(session.stage.prim(at: PrimPath("/Obj")!) == nil)
        _ = await callOK(server, "sculpt_build_pass")
        #expect(session.stage.prim(at: PrimPath("/Obj")!) != nil)
    }

    @Test func cleanFalseKeepsPreviousBuild() async {
        let session = Fixtures.emptySession()
        let server = Fixtures.server(session: session)
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.weldedSpec())])
        _ = await callOK(server, "sculpt_build_pass")
        let replaced = await callOK(server, "sculpt_author_spec",
            ["spec": Self.specArg(Self.weldedSpec()), "clean": false])
        #expect(replaced["cleaned"].stringArrayValue == [])
        #expect(session.stage.prim(at: PrimPath("/Obj")!) != nil)
    }

    @Test func orphanedLooksMaterialsAreRemoved() throws {
        let session = Fixtures.session()
        // Bind a material to /Root/Box, then remove /Root — the material is
        // orphaned and must be cleaned; nothing else binds it.
        let box = try session.resolve(.object(["path": .string("/Root/Box")]))
        let command = try #require(CreateMaterialCommand.make(bindingTo: box, name: "paint", in: session.stage))
        _ = try session.mutate(command)
        #expect(session.stage.prim(at: PrimPath("/Looks/paint")!) != nil)
        let rootPath = try session.resolve(.object(["path": .string("/Root")]))
        _ = try session.mutate(try MutateTools.removeCommand(for: rootPath, session: session), removed: [rootPath])

        let removed = try SculptTools.removeOrphanedLooksMaterials(session: session)
        #expect(removed == ["/Looks/paint"])
        #expect(session.stage.prim(at: PrimPath("/Looks/paint")!) == nil)
    }

    @Test func boundLooksMaterialsSurviveOrphanSweep() throws {
        let session = Fixtures.session()
        let box = try session.resolve(.object(["path": .string("/Root/Box")]))
        let command = try #require(CreateMaterialCommand.make(bindingTo: box, name: "kept", in: session.stage))
        _ = try session.mutate(command)
        let removed = try SculptTools.removeOrphanedLooksMaterials(session: session)
        #expect(removed.isEmpty)
        #expect(session.stage.prim(at: PrimPath("/Looks/kept")!) != nil)
    }

    @Test func noLooksScopeMeansNothingToSweep() throws {
        #expect(try SculptTools.removeOrphanedLooksMaterials(session: Fixtures.emptySession()).isEmpty)
    }

    // MARK: - Shared spec-named materials (#158)

    @Test func materialStepsShareOneMaterialPerSpecID() {
        let a = ComponentNode(name: "A", shape: .primitive(.box), materialID: "steel", attachment: .root)
        let b = ComponentNode(name: "B", shape: .primitive(.box), materialID: "steel", attachment: .weld)
        let root = ComponentNode(name: "Obj", shape: .group, children: [a, b])
        let spec = ObjectSculptSpec(
            name: "Obj", objectClass: .object, root: root,
            materials: [MaterialSpec(id: "steel", baseColor: [0.5, 0.5, 0.5])])
        let steps = BuildPlanner.plan(for: spec, pass: .material)
        #expect(steps == [
            .createMaterial(targetPath: "/Obj/A", material: spec.materials[0]),
            .bindMaterial(targetPath: "/Obj/B", sourcePath: "/Obj/A"),
        ])
    }

    @Test func createMaterialStepReusesExistingSpecMaterial() async throws {
        let session = Fixtures.session()
        let material = MaterialSpec(id: "steel", baseColor: [0.5, 0.5, 0.5])
        let first = try await SculptTools.execute(
            step: .createMaterial(targetPath: "/Root/Box", material: material), session: session)
        #expect(first == "/Looks/steel")
        // Re-running against another prim binds the existing /Looks/steel
        // instead of minting steel_1.
        let second = try await SculptTools.execute(
            step: .createMaterial(targetPath: "/Root/Lid", material: material), session: session)
        #expect(second == "/Looks/steel")
        #expect(session.stage.prim(at: PrimPath("/Looks/steel_1")!) == nil)
    }

    @Test func sanitizedPrimNameCoercesIllegalIdentifiers() {
        #expect(CreateMaterialCommand.sanitizedPrimName("red_paint") == "red_paint")
        #expect(CreateMaterialCommand.sanitizedPrimName("red paint!") == "red_paint_")
        #expect(CreateMaterialCommand.sanitizedPrimName("1st") == "_1st")
        #expect(CreateMaterialCommand.sanitizedPrimName("") == "Material")
    }

    // MARK: - Assessment surfacing (#157)

    @Test func assessSurfacesFloorAndHonorsAlpha() async {
        let server = Fixtures.server(session: Fixtures.session())
        let cutout = await callOK(server, "sculpt_assess",
            ["hints": ["barrel"], "width": 512, "height": 512, "hasAlpha": true])
        #expect(cutout["policy"]["similarityFloor"].doubleValue == 0.5)
        #expect(cutout["policy"]["requireCompliance"].boolValue == true)
        let flattened = await callOK(server, "sculpt_assess",
            ["hints": ["barrel"], "width": 512, "height": 512, "hasAlpha": false])
        #expect(flattened["policy"]["similarityFloor"].doubleValue == 0.3)
        #expect(flattened["notes"].stringArrayValue?.contains { $0.contains("similarityFloor") } == true)
    }

    // MARK: - Blockout note (#160)

    @Test func blockoutBuildExplainsPlacement() async {
        let server = Fixtures.server(session: Fixtures.emptySession())
        _ = await callOK(server, "sculpt_author_spec", ["spec": Self.specArg(Self.weldedSpec())])
        let result = await callOK(server, "sculpt_build_pass")
        #expect(result["note"].stringValue?.contains("structural") == true)
    }

    // MARK: - bbox space labels (#160)

    @Test func bboxPayloadsLabelWorldSpace() async {
        let server = Fixtures.server(session: Fixtures.session())
        let scene = await callOK(server, "query_scene", ["name": "Box"])
        #expect(scene["prims"].arrayValue?.first?["bboxSpace"].stringValue == "world")
        let stats = await callOK(server, "render_views", ["statsOnly": true])
        #expect(stats["subjects"].arrayValue?.first?["bboxSpace"].stringValue == "world")
    }

    // MARK: - Helpers

    static func specArg(_ spec: ObjectSculptSpec) -> JSONValue {
        try! JSONValue.parse(spec.encoded())
    }
}
