import Testing
import Foundation
@testable import EditorUI
import USDCore
import EditingKit

/// The guided tour drives real commands against its sandbox document; these
/// tests step the engine through every stage and assert the *stage truth*
/// after each — insert lands, transforms commit, the extrude adds geometry,
/// and the whole story unwinds through undo. Animation tweens run for real
/// (the steps await them), so this suite takes a few seconds by design.
@MainActor
struct TutorialEngineTests {

    /// Advance one step and wait for its animation/action to finish.
    private func advance(_ engine: TutorialEngine) async throws {
        let before = engine.stepIndex
        engine.next()
        #expect(engine.stepIndex == before + 1)
        var waited = 0.0
        while engine.isAnimating {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
            try #require(waited < 15, "step \(engine.stepIndex) never finished animating")
        }
    }

    @Test func tourStepsDriveRealUndoableEdits() async throws {
        let engine = try TutorialEngine()
        let document = engine.document
        var finished = false
        engine.onFinished = { finished = true }

        // The scene file exists and starts with the cube.
        let url = try #require(document.modelURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(document.snapshot.prim(at: TutorialScene.meshPath)?.typeName == "Mesh")

        // Intro hides the cube (the app does this via start(); do it directly
        // here so the test doesn't depend on the 900 ms baseline delay).
        document.delete(TutorialScene.cubePath)
        #expect(document.snapshot.prim(at: TutorialScene.cubePath) == nil)

        // Step 1 — Create: the cube is back, selected, and undoable.
        try await advance(engine)
        #expect(document.snapshot.prim(at: TutorialScene.cubePath) != nil)
        #expect(document.selection.contains(TutorialScene.cubePath))
        #expect(document.undoLabel == "Add TutorialCube")

        // Step 2 — Move: a committed transform with the expected translation.
        try await advance(engine)
        let moved = document.transform(at: TutorialScene.cubePath)
        #expect(abs(moved.translation[0] - 0.9) < 1e-9)
        #expect(abs(moved.translation[1] - 0.55) < 1e-9)
        #expect(document.undoLabel == "Move TutorialCube")

        // Step 3 — Rotate: rotation committed, translation preserved.
        try await advance(engine)
        let rotated = document.transform(at: TutorialScene.cubePath)
        #expect(abs(rotated.rotationEulerDegrees[1] - 30) < 1e-6)
        #expect(abs(rotated.translation[0] - 0.9) < 1e-9)

        // Step 4 — Extrude: session committed, the mesh gained vertices
        // (a box has 8; an extruded top face adds 4 more).
        try await advance(engine)
        #expect(document.meshEdit == nil, "session should have committed")
        let mesh = try #require(document.snapshot.prim(at: TutorialScene.meshPath))
        guard case .float3Array(let points)? = mesh.attribute(named: "points")?.value else {
            Issue.record("extruded mesh lost its points attribute")
            return
        }
        #expect(points.count / 3 == 12)
        #expect(document.undoLabel?.contains("Extrude") == true)

        // Step 5 — Undo/redo demo ends with the extrude restored.
        try await advance(engine)
        guard case .float3Array(let after)? = document.snapshot
            .prim(at: TutorialScene.meshPath)?.attribute(named: "points")?.value else {
            Issue.record("mesh lost its points attribute after undo/redo")
            return
        }
        #expect(after.count / 3 == 12)

        // Step 6 is the finish card; the button then completes the tour.
        try await advance(engine)
        #expect(engine.isLastStep)
        engine.next()
        #expect(finished)
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "the sandbox temp file should be cleaned up")

        // The whole story unwinds: undo everything → the stage is empty
        // (delete + create + move + rotate + extrude + redo all on the stack).
        while document.canUndo { document.undo() }
        #expect(document.snapshot.prim(at: TutorialScene.meshPath)?.typeName == "Mesh")
    }

    @Test func skipCleansUpImmediately() throws {
        let engine = try TutorialEngine()
        var finished = false
        engine.onFinished = { finished = true }
        let url = try #require(engine.document.modelURL)
        engine.skip()
        #expect(finished)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Regression (memory leak): the orbit task must not retain the engine.
    /// It used to `guard let self` once before its unbounded loop, so the task
    /// held the engine (and its sandbox document) strongly forever — `deinit`
    /// could never run and the 30 Hz camera loop outlived an abandoned tour.
    /// The loop now re-acquires `self` weakly each frame, so releasing the
    /// engine mid-tour deallocates it and ends the orbit.
    @Test func abandonedTourReleasesTheEngine() async throws {
        var engine: TutorialEngine? = try TutorialEngine()
        let url = try #require(engine?.document.modelURL)
        defer { try? FileManager.default.removeItem(at: url) }
        weak var leaked = engine
        engine?.start()
        // Let the orbit loop actually begin (start() sleeps 900 ms first),
        // so the test exercises the steady-state loop, not the warm-up.
        try await Task.sleep(for: .milliseconds(1100))
        engine = nil
        // The loop releases its per-frame strong ref between iterations
        // (~33 ms); give it a few cycles to observe the drop and unwind.
        var waited = 0.0
        while leaked != nil, waited < 3 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(leaked == nil, "the orbit task must not keep the engine alive")
    }

    @Test func sceneSerializesAValidCube() throws {
        let (snapshot, url) = try TutorialScene.makeStage()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("#usda 1.0"))
        #expect(text.contains("def Mesh \"Geo\""))
        #expect(text.contains("uniform token subdivisionScheme = \"none\""))
        let mesh = try #require(snapshot.prim(at: TutorialScene.meshPath))
        #expect(EditorDocument.flatMesh(from: mesh) != nil)
    }
}
