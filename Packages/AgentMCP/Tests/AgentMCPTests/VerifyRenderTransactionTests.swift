import Foundation
import Testing
import USDCore
@testable import AgentMCP

@Suite struct VerifyToolTests {

    @Test func validateAndCompliance() async {
        let server = Fixtures.server(session: Fixtures.session())
        let report = await callOK(server, "validate")
        #expect(report["diagnostics"].arrayValue != nil)
        let strictReport = await callOK(server, "validate", ["profile": "arkit-strict"])
        _ = strictReport
        _ = await callError(server, "validate", ["profile": "nonsense"])

        let compliance = await callOK(server, "check_compliance")
        #expect(compliance["profile"].stringValue == "arkit")
        #expect(compliance["isExportAllowed"].boolValue != nil)
        _ = await callError(server, "check_compliance", ["profile": "nope"])
    }

    @Test func strictnessToggle() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let set = await callOK(server, "set_strictness", ["mode": "off"])
        #expect(set["strictness"].stringValue == "off")
        #expect(session.strictness == .off)
        let mutated = await callOK(server, "set_active", ["path": "/Root/Lid", "active": false])
        #expect(mutated["validation"].isNull)
        _ = await callOK(server, "set_strictness", ["mode": "strict"])
        _ = await callError(server, "set_strictness", ["mode": "pedantic"])
    }

    @Test func checkMeshHealthyAndBroken() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let healthy = await callOK(server, "check_mesh", ["path": "/Root/Box"])
        #expect(healthy["pass"].boolValue == true)
        #expect(healthy["eulerCharacteristic"].intValue == 2)
        // Closed-mesh requirement: a box with a deleted face fails allowBoundaries=false.
        _ = await callOK(server, "edit_mesh",
                         ["path": "/Root/Lid", "ops": [["op": "delete_faces", "faces": [0]]]])
        let open = await callOK(server, "check_mesh", ["path": "/Root/Lid", "allowBoundaries": false])
        #expect(open["pass"].boolValue == false)
        #expect(open["violations"].arrayValue?.isEmpty == false)
        // Non-mesh prim → structured error.
        _ = await callError(server, "check_mesh", ["path": "/Root"])
        // Corrupt topology (indices out of range) → pass=false via MeshIO failure.
        _ = await callOK(server, "set_attribute",
                         ["path": "/Root/Lid", "name": "faceVertexIndices", "type": "intArray",
                          "value": [0, 1, 999]])
        _ = await callOK(server, "set_attribute",
                         ["path": "/Root/Lid", "name": "faceVertexCounts", "type": "intArray", "value": [3]])
        let corrupt = await callOK(server, "check_mesh", ["path": "/Root/Lid"])
        #expect(corrupt["pass"].boolValue == false)
    }

    @Test func scoreGateLadder() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        let scored = await callOK(server, "score", ["intent": "a crate with a lid"])
        #expect(scored["intent"].stringValue == "a crate with a lid")
        let gates = scored["gates"].arrayValue!
        #expect(gates.count == 4)
        #expect(gates.map { $0["gate"].stringValue! } == ["schema", "meshIntegrity", "scaleSanity", "spatial"])
        // Fixture scene is clean geometry — mesh + spatial should pass.
        #expect(gates[1]["pass"].boolValue == true)
        #expect(gates[3]["pass"].boolValue == true)
        #expect(scored["score"].doubleValue! >= 0.5)

        // Break spatial: overlap the two boxes.
        _ = await callOK(server, "set_transform", [
            "path": "/Root/Lid",
            "relativeTo": ["anchor": "/Root/Box", "rule": "inside_center"],
        ])
        let overlapping = await callOK(server, "score")
        let spatial = overlapping["gates"].arrayValue![3]
        #expect(spatial["pass"].boolValue == false)
        #expect(spatial["interpenetrations"].arrayValue?.isEmpty == false)
        #expect(overlapping["pass"].boolValue == false)

        // Break scale: giant scene vs tight expectation.
        _ = await callOK(server, "set_transform", ["path": "/Root", "scale": [500, 500, 500]])
        let huge = await callOK(server, "score", ["expectedMaxExtent": 10])
        #expect(huge["gates"].arrayValue![2]["pass"].boolValue == false)
    }
}

/// Stub renderer capturing invocations and writing fake images.
struct StubRenderer: RenderExecuting {
    struct Invocation: Sendable { var camera: String; var size: Int }
    let recorded: @Sendable (Invocation) -> Void
    var failFor: String?

    func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
        if let failFor, cameraPath.contains(failFor) {
            throw ToolError.failed("stub render failure")
        }
        // Prove the authored stage exists and contains the camera prim.
        let usda = try String(contentsOf: stageURL, encoding: .utf8)
        guard usda.contains(String(cameraPath.dropFirst())) else {
            throw ToolError.failed("camera \(cameraPath) not in stage")
        }
        try Data("png".utf8).write(to: outputURL)
        recorded(Invocation(camera: cameraPath, size: size))
    }
}

@Suite struct RenderToolTests {

    @Test func statsOnlyDefaultWithoutRenderer() async {
        let server = Fixtures.server(session: Fixtures.session())
        let stats = await callOK(server, "render_views")
        #expect(stats["statsOnly"].boolValue == true)
        let subjects = stats["subjects"].arrayValue!
        #expect(subjects.count == 1)
        #expect(subjects[0]["triangles"].intValue == 24)  // 2 boxes × 6 quads × 2 tris
        // Isolated subtree.
        let isolated = await callOK(server, "render_views", ["paths": ["/Root/Box"], "statsOnly": true])
        #expect(isolated["subjects"].arrayValue?.first?["triangles"].intValue == 12)
        // statsOnly=false with no renderer → structured unsupported error.
        let message = await callError(server, "render_views", ["statsOnly": false])
        #expect(message.contains("no renderer"))
        _ = await callError(server, "render_views", ["views": ["hero-shot"]])
    }

    @Test func rendersEveryViewThroughStub() async {
        let recorder = Recorder()
        let renderer = StubRenderer(recorded: { inv in recorder.append(inv) })
        let work = Fixtures.tempDirectory()
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(renderer: renderer, workDirectory: work))

        let rendered = await callOK(server, "render_views", ["size": 128])
        #expect(rendered["statsOnly"].boolValue == false)
        let images = rendered["images"].arrayValue!
        #expect(images.count == 4)
        #expect(recorder.snapshot().map(\.camera).sorted()
                == ["/AgentCam_front", "/AgentCam_persp", "/AgentCam_side", "/AgentCam_top"])
        #expect(recorder.snapshot().allSatisfy { $0.size == 128 })
        for image in images {
            #expect(FileManager.default.fileExists(atPath: image["path"].stringValue!))
        }

        // Isolated render re-roots the subtree.
        let solo = await callOK(server, "render_views", ["paths": ["/Root/Box"], "views": ["front"]])
        #expect(solo["images"].arrayValue?.count == 1)

        // Size bounds + renderer failure surfaces as tool error.
        _ = await callError(server, "render_views", ["size": 16])
        let failServer = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(
                renderer: StubRenderer(recorded: { _ in }, failFor: "top"),
                workDirectory: Fixtures.tempDirectory()))
        let failure = await callError(failServer, "render_views", ["views": ["top"]])
        #expect(failure.contains("render 'top' failed"))
    }

    @Test func renderRejectsEmptyGeometry() async {
        let empty = EditSession(snapshot: StageSnapshot(
            rootPrims: [Prim(path: PrimPath("/Empty")!, typeName: "Xform")]))
        let server = Fixtures.server(
            session: empty,
            configuration: .init(renderer: StubRenderer(recorded: { _ in }),
                                 workDirectory: Fixtures.tempDirectory()))
        let message = await callError(server, "render_views")
        #expect(message.contains("nothing renderable"))
    }

    @Test func cameraMathFramesSubject() {
        let bbox = GeometryProbe.BBox(min: [-1, -1, -1], max: [1, 1, 1])
        for view in RenderTools.defaultViews {
            let camera = RenderTools.camera(view: view, framing: bbox)
            #expect(camera != nil, "no camera for \(view)")
            #expect(camera?.typeName == "Camera")
        }
        #expect(RenderTools.camera(view: "hero", framing: bbox) == nil)
        // lookAt: front camera positioned +Z, looking back at origin.
        let matrix = RenderTools.lookAt(eye: [0, 0, 5], center: [0, 0, 0], up: [0, 1, 0])
        #expect(matrix[12] == 0 && matrix[13] == 0 && matrix[14] == 5)
        // z basis row points from center to eye (+Z).
        #expect(abs(matrix[10] - 1) < 1e-9)
        // Degenerate up vector falls back without NaN.
        let degenerate = RenderTools.lookAt(eye: [0, 0, 0], center: [0, 0, 0], up: [0, 0, 0])
        #expect(degenerate.allSatisfy { $0.isFinite })
    }

    @Test func raycastTool() async {
        let server = Fixtures.server(session: Fixtures.session())
        let hit = await callOK(server, "raycast", ["origin": [0, 10, 0], "direction": [0, -1, 0]])
        #expect(hit["hit"].boolValue == true)
        #expect(hit["path"].stringValue == "/Root/Lid")
        let miss = await callOK(server, "raycast", ["origin": [99, 0, 0], "direction": [0, 1, 0]])
        #expect(miss["hit"].boolValue == false)
        _ = await callError(server, "raycast", ["origin": [0, 0], "direction": [0, -1, 0]])
    }
}

@Suite struct ArbitraryAngleRenderTests {

    private func renderServer(failFor: String? = nil) -> (MCPServer, URL) {
        let work = Fixtures.tempDirectory()
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(renderer: StubRenderer(recorded: { _ in }, failFor: failFor),
                                 workDirectory: work))
        return (server, work)
    }

    @Test func rendersArbitraryOrbitAngles() async {
        let recorder = Recorder()
        let work = Fixtures.tempDirectory()
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(renderer: StubRenderer(recorded: { recorder.append($0) }),
                                 workDirectory: work))
        // Angles-only: no default named views injected.
        let rendered = await callOK(server, "render_views", [
            "angles": [["azimuth": 30, "elevation": 20], ["azimuth": 120, "elevation": 80, "distance": 1.5]],
        ])
        let images = rendered["images"].arrayValue!
        #expect(images.count == 2)
        #expect(images.map { $0["view"].stringValue! } == ["angle0", "angle1"])
        #expect(recorder.snapshot().map(\.camera).sorted() == ["/AgentCam_angle0", "/AgentCam_angle1"])

        // Named views and custom angles combine.
        let both = await callOK(server, "render_views", ["views": ["front"], "angles": [["azimuth": 45, "elevation": 30]]])
        #expect(both["images"].arrayValue?.map { $0["view"].stringValue! } == ["front", "angle0"])
    }

    @Test func angleValidation() async {
        let (server, _) = renderServer()
        _ = await callError(server, "render_views", ["angles": "nope"])
        _ = await callError(server, "render_views", ["angles": [["azimuth": 10]]])
        _ = await callError(server, "render_views", ["angles": [["azimuth": 10, "elevation": 120]]])
        _ = await callError(server, "render_views", ["angles": [["azimuth": 10, "elevation": 10, "distance": 0]]])
        // Empty views + empty angles → nothing to render.
        _ = await callError(server, "render_views", ["views": [], "angles": []])
        // Bad named view still rejected.
        _ = await callError(server, "render_views", ["views": ["hero"]])
        // Angle render failure surfaces the shot name.
        let (failing, _) = renderServer(failFor: "angle0")
        let failure = await callError(failing, "render_views", ["angles": [["azimuth": 0, "elevation": 45]]])
        #expect(failure.contains("render 'angle0' failed"))
    }

    @Test func findBestViewRanksAngles() async {
        let server = Fixtures.server(session: Fixtures.session())
        let result = await callOK(server, "find_best_view", ["count": 2])
        let angles = result["angles"].arrayValue!
        #expect(angles.count == 2)
        // Coverage is monotonically non-increasing (best first).
        let coverages = angles.map { $0["coverage"].doubleValue! }
        #expect(coverages[0] >= coverages[1])
        #expect(coverages.allSatisfy { $0 > 0 })
        #expect(angles[0]["azimuth"].doubleValue != nil)

        // Isolated subject + default count.
        let solo = await callOK(server, "find_best_view", ["paths": ["/Root/Box"]])
        #expect(solo["angles"].arrayValue?.count == 3)

        // Errors: bad count, empty geometry.
        _ = await callError(server, "find_best_view", ["count": 0])
        let empty = EditSession(snapshot: StageSnapshot(
            rootPrims: [Prim(path: PrimPath("/Empty")!, typeName: "Xform")]))
        let emptyServer = Fixtures.server(session: empty)
        let message = await callError(emptyServer, "find_best_view")
        #expect(message.contains("nothing measurable"))
    }

    @Test func sphericalCameraGeometry() {
        let bbox = GeometryProbe.BBox(min: [-1, -1, -1], max: [1, 1, 1])
        // Azimuth 0 / elevation 0 sits on +Z, like the front view.
        let front = RenderTools.eyePosition(
            angle: .init(azimuth: 0, elevation: 0), distance: 5, center: [0, 0, 0])
        #expect(abs(front[2] - 5) < 1e-9 && abs(front[0]) < 1e-9 && abs(front[1]) < 1e-9)
        // Elevation 90 lifts straight up and swaps the up reference at the pole.
        let top = RenderTools.eyePosition(
            angle: .init(azimuth: 0, elevation: 90), distance: 5, center: [0, 0, 0])
        #expect(abs(top[1] - 5) < 1e-9)
        #expect(RenderTools.upVector(elevation: 90) == [0, 0, -1])
        #expect(RenderTools.upVector(elevation: 30) == [0, 1, 0])

        let cam = RenderTools.sphericalCamera(
            name: "angle0", angle: .init(azimuth: 45, elevation: 30, distance: 2), framing: bbox)
        #expect(cam.typeName == "Camera")
        #expect(cam.path.description == "/AgentCam_angle0")

        // A frontal box projects a unit-ish square; footprint is positive.
        let footprint = RenderTools.projectedFootprint(framing: bbox, angle: .init(azimuth: 0, elevation: 0))
        #expect(footprint > 0)
        #expect(RenderTools.corners(of: bbox).count == 8)
    }
}

/// Tiny thread-safe recorder for stub callbacks.
final class Recorder: @unchecked Sendable {
    private var items: [StubRenderer.Invocation] = []
    private let lock = NSLock()
    func append(_ item: StubRenderer.Invocation) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }
    func snapshot() -> [StubRenderer.Invocation] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

@Suite struct TransactionToolTests {

    @Test func undoRedoUndoToSaveFlow() async throws {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        let empty = await callOK(server, "undo")
        #expect(empty["undone"].isNull)
        let emptyRedo = await callOK(server, "redo")
        #expect(emptyRedo["redone"].isNull)

        _ = await callOK(server, "set_active", ["path": "/Root/Lid", "active": false])
        let second = await callOK(server, "set_active", ["path": "/Root/Box", "active": false])
        #expect(second["undoToken"].intValue == 2)

        let undone = await callOK(server, "undo")
        #expect(undone["undone"].stringValue?.contains("Disable") == true)
        let redone = await callOK(server, "redo")
        #expect(redone["redone"].stringValue?.contains("Disable") == true)

        let rewound = await callOK(server, "undo_to", ["token": 0])
        #expect(rewound["undone"].arrayValue?.count == 2)
        #expect(session.stage.prim(at: PrimPath("/Root/Lid")!)!.isActive)
        _ = await callError(server, "undo_to", ["token": 5])
        _ = await callError(server, "undo_to", .object([:]))

        let out = Fixtures.tempDirectory().appendingPathComponent("saved.usda")
        let saved = await callOK(server, "save", ["url": .string(out.path)])
        #expect(saved["saved"].stringValue == out.path)
        _ = await callError(server, "save")  // no sourceURL, no url
    }
}
