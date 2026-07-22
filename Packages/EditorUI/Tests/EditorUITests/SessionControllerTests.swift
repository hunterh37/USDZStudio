import Testing
import Foundation
import USDCore
import EditingKit
import ViewportKit
import SessionKit
@testable import EditorUI

/// End-to-end coverage of the session lifecycle service: begin → capture →
/// (relaunch) → findRecoverable → restore, plus discard/endActive — all against
/// a temp WAL directory and an in-memory envelope store.
@MainActor
struct SessionControllerTests {

    private func sampleSnapshot() -> StageSnapshot {
        let body = Prim(path: PrimPath("/Car/Body")!, typeName: "Mesh")
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [body])
        return StageSnapshot(rootPrims: [car])
    }

    private func makeController(root: URL, envelopes: InMemoryEnvelopeStore) -> SessionController {
        SessionController(sessions: EditingKit.SessionStore(root: root), envelopes: envelopes)
    }

    @Test func beginCaptureRecoverAndRestoreScratchScene() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let envelopes = InMemoryEnvelopeStore()

        // Session 1: open a scratch scene, edit it, capture.
        let controller = makeController(root: root, envelopes: envelopes)
        let baseline = sampleSnapshot()
        let journal = controller.begin(for: nil)
        #expect(journal != nil)
        #expect(controller.activeDirectory != nil)
        let doc = EditorDocument(snapshot: baseline, journal: journal)  // writes checkpoint
        controller.attach(doc)
        doc.setVisibility(PrimPath("/Car/Body")!, .invisible)           // WAL grows
        controller.capture(doc)

        // Session 2 (relaunch): a new controller over the same root recovers it.
        let relaunch = makeController(root: root, envelopes: envelopes)
        let recoverable = try #require(relaunch.findRecoverable())
        #expect(recoverable.sourceChangedOnDisk == false)              // scratch scene
        let embedded = try #require(relaunch.embeddedBaseline(for: recoverable))
        let restored = relaunch.restore(recoverable, baseline: embedded)

        // The edit replayed onto the *baseline* (not double-applied).
        #expect(restored.snapshot.prim(at: PrimPath("/Car/Body")!)?.visibility == .invisible)
        #expect(restored.canUndo)
        #expect(relaunch.activeDirectory == recoverable.plan.directory) // adopted
    }

    @Test func capturesAndRestoresShellOwnedViewState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let envelopes = InMemoryEnvelopeStore()

        let controller = makeController(root: root, envelopes: envelopes)
        let journal = controller.begin(for: nil)
        let doc = EditorDocument(snapshot: sampleSnapshot(), journal: journal)
        controller.attach(doc)
        doc.setVisibility(PrimPath("/Car/Body")!, .invisible)   // gives the WAL work
        // Capture with the shell-owned state the shell would supply.
        let pose = ViewportCameraPose(target: SIMD3(1, 2, 3), distance: 7, azimuth: 0.5, elevation: 0.4)
        controller.capture(
            doc,
            collapsed: [PrimPath("/Car")!],
            camera: pose,
            environment: EnvironmentSettings(exposureEV: 3),
            panelVisibility: ["diff": true, "validation": false],
            playbackPosition: 4.2)

        // Relaunch: the envelope carries the shell-owned view state.
        let relaunch = makeController(root: root, envelopes: envelopes)
        let recoverable = try #require(relaunch.findRecoverable())
        let view = recoverable.document.viewState
        #expect(view.collapsedPaths == ["/Car"])
        #expect(view.restoredCameraPose == pose)
        #expect(view.environment?.exposureEV == 3)
        #expect(view.panelVisibility["diff"] == true)
        #expect(view.playbackPosition == 4.2)
    }

    @Test func findRecoverableNilWhenNothingCaptured() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(root: root, envelopes: InMemoryEnvelopeStore())
        #expect(controller.findRecoverable() == nil)
    }

    @Test func findRecoverableSkipsSessionsWithoutEnvelope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A WAL session with records but no envelope written (plain crash-only WAL).
        let sessions = EditingKit.SessionStore(root: root)
        let session = try sessions.startSession(for: nil)
        try session.journal.append(.checkpoint(sourceURL: nil))
        try session.journal.append(.command(label: "X", forward: [], inverse: []))
        let controller = makeController(root: root, envelopes: InMemoryEnvelopeStore())
        #expect(controller.findRecoverable() == nil)                   // no envelope → skipped
    }

    @Test func captureNoOpWithoutActiveSession() {
        let controller = makeController(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            envelopes: InMemoryEnvelopeStore())
        // No begin() → no active directory → capture is a safe no-op.
        controller.capture(EditorDocument(snapshot: sampleSnapshot()))
        #expect(controller.activeDirectory == nil)
    }

    @Test func discardRemovesRecoverableSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let envelopes = InMemoryEnvelopeStore()
        let controller = makeController(root: root, envelopes: envelopes)
        let journal = controller.begin(for: nil)
        let doc = EditorDocument(snapshot: sampleSnapshot(), journal: journal)
        controller.attach(doc)
        doc.setVisibility(PrimPath("/Car/Body")!, .invisible)
        controller.capture(doc)

        let relaunch = makeController(root: root, envelopes: envelopes)
        let recoverable = try #require(relaunch.findRecoverable())
        relaunch.discard(recoverable)
        #expect(relaunch.findRecoverable() == nil)
    }

    @Test func endActiveClearsActiveSession() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(root: root, envelopes: InMemoryEnvelopeStore())
        _ = controller.begin(for: nil)
        #expect(controller.activeDirectory != nil)
        controller.endActive()
        #expect(controller.activeDirectory == nil)
    }

    @Test func resetClearsActiveAndAllRecoverableSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let envelopes = InMemoryEnvelopeStore()

        // A recoverable session left behind by a prior launch.
        let prior = makeController(root: root, envelopes: envelopes)
        let priorJournal = prior.begin(for: nil)
        let priorDoc = EditorDocument(snapshot: sampleSnapshot(), journal: priorJournal)
        prior.attach(priorDoc)
        priorDoc.setVisibility(PrimPath("/Car/Body")!, .invisible)
        prior.capture(priorDoc)

        // This launch's controller sees it, and also opens its own active session.
        let controller = makeController(root: root, envelopes: envelopes)
        #expect(controller.findRecoverable() != nil)
        _ = controller.begin(for: URL(fileURLWithPath: "/tmp/live.usda"))
        #expect(controller.activeDirectory != nil)

        controller.reset()

        #expect(controller.activeDirectory == nil)             // active session ended
        #expect(controller.findRecoverable() == nil)           // leftovers swept too
    }

    @Test func beginSupersedesPriorSession() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(root: root, envelopes: InMemoryEnvelopeStore())
        _ = controller.begin(for: nil)
        let first = controller.activeDirectory
        _ = controller.begin(for: URL(fileURLWithPath: "/tmp/next.usda"))
        #expect(controller.activeDirectory != first)                   // fresh session dir
    }
}
