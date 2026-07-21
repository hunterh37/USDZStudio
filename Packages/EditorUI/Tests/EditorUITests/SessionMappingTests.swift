import Testing
import Foundation
import USDCore
import EditingKit
import ViewportKit
import SessionKit
@testable import EditorUI

/// Coverage for the EditorUI ↔ SessionKit bridge: view-state capture/apply,
/// descriptor capture, and WAL-replay document restore.
@MainActor
struct SessionMappingTests {

    private func sampleSnapshot() -> StageSnapshot {
        let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh")
        let body = Prim(path: PrimPath("/Car/Body")!, typeName: "Mesh")
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [body, wheel])
        return StageSnapshot(rootPrims: [car])
    }

    // MARK: ViewState capture / apply

    @Test func capturesDocumentOwnedViewState() {
        let doc = EditorDocument(snapshot: sampleSnapshot())
        doc.selection = Selection([PrimPath("/Car/Body")!, PrimPath("/Car/Wheel")!])
        doc.gizmoMode = .rotate
        doc.gizmoOrientation = .local
        doc.gizmoPivotMode = .individual
        doc.restoreIsolation([PrimPath("/Car/Body")!])

        let view = ViewState.capture(from: doc)
        #expect(view.primarySelectionPath == "/Car/Body")
        #expect(Set(view.selectionPaths) == ["/Car/Body", "/Car/Wheel"])
        #expect(view.gizmoMode == "rotate")
        #expect(view.gizmoOrientation == "local")
        #expect(view.gizmoPivotMode == "individual")
        #expect(view.isolationRoots == ["/Car/Body"])
    }

    @Test func capturesShellOwnedViewState() {
        let doc = EditorDocument(snapshot: sampleSnapshot())
        let pose = ViewportCameraPose(target: SIMD3(1, 0, 0), distance: 4, azimuth: 1, elevation: 0.2)
        let view = ViewState.capture(
            from: doc, collapsed: [PrimPath("/Car")!], camera: pose,
            environment: EnvironmentSettings(exposureEV: 2),
            panelVisibility: ["diff": true], playbackPosition: 1.5)
        #expect(view.collapsedPaths == ["/Car"])
        #expect(view.restoredCameraPose == pose)
        #expect(view.environment?.exposureEV == 2)
        #expect(view.panelVisibility["diff"] == true)
        #expect(view.playbackPosition == 1.5)
    }

    @Test func appliesViewStateRestoringSelectionPrimaryFirst() {
        let doc = EditorDocument(snapshot: sampleSnapshot())
        let view = ViewState(
            selectionPaths: ["/Car/Body", "/Car/Wheel"],
            primarySelectionPath: "/Car/Wheel",
            gizmoMode: "scale", gizmoOrientation: "local", gizmoPivotMode: "individual",
            isolationRoots: ["/Car/Body"])
        doc.applySessionViewState(view)
        #expect(doc.selection.primary == PrimPath("/Car/Wheel")!)   // primary hoisted first
        #expect(doc.selection.paths.count == 2)
        #expect(doc.gizmoMode == .scale)
        #expect(doc.gizmoOrientation == .local)
        #expect(doc.gizmoPivotMode == .individual)
        #expect(doc.isolation.roots == [PrimPath("/Car/Body")!])
    }

    @Test func appliesViewStateDropsStalePathsAndUnknownEnums() {
        let doc = EditorDocument(snapshot: sampleSnapshot())
        let view = ViewState(
            selectionPaths: ["/Car/Body", "/Gone/Prim"],
            primarySelectionPath: "/Gone/Prim",       // not on stage → skipped
            gizmoMode: "bogus",                        // unknown → gizmo unchanged
            isolationRoots: ["/Also/Missing"])         // not on stage → no isolation
        doc.gizmoMode = .translate
        doc.applySessionViewState(view)
        #expect(doc.selection.paths == [PrimPath("/Car/Body")!])
        #expect(doc.gizmoMode == .translate)
        #expect(doc.isolation.isActive == false)
    }

    @Test func restoredCollapsedKeepsOnlyLivePaths() {
        let snapshot = sampleSnapshot()
        let view = ViewState(collapsedPaths: ["/Car", "/Ghost"])
        #expect(view.restoredCollapsed(in: snapshot) == [PrimPath("/Car")!])
    }

    // MARK: DocumentSession capture

    @Test func capturesScratchSceneWithEmbeddedBaseline() {
        let doc = EditorDocument(snapshot: sampleSnapshot())   // no modelURL
        let baseline = sampleSnapshot()
        let descriptor = DocumentSession.capture(document: doc, embeddedBaseline: baseline)
        #expect(descriptor.source == nil)
        #expect(descriptor.fingerprint == nil)
        #expect(descriptor.embeddedSnapshot == baseline)
    }

    @Test func capturesFileBackedSceneWithFingerprint() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-\(UUID().uuidString).usda")
        try Data("#usda 1.0\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let doc = EditorDocument(snapshot: sampleSnapshot(), modelURL: file)
        let descriptor = DocumentSession.capture(document: doc, embeddedBaseline: nil)
        #expect(descriptor.source?.displayName == file.lastPathComponent)
        #expect(descriptor.fingerprint != nil)
        #expect(descriptor.embeddedSnapshot == nil)
    }

    // MARK: Restore (WAL replay)

    /// The post-checkpoint tail of a WAL (drop the opening checkpoint records).
    private func tail(of journal: InMemoryCommandJournal) throws -> [JournalRecord] {
        try journal.readAll().filter { if case .checkpoint = $0 { false } else { true } }
    }

    @Test func restoreReplaysWALOntoBaselineAndAppliesViewState() throws {
        let baseline = sampleSnapshot()
        // Produce a WAL by editing a journaled document over the baseline.
        let journal = InMemoryCommandJournal()
        let editing = EditorDocument(snapshot: baseline, journal: journal)
        editing.setVisibility(PrimPath("/Car/Body")!, .invisible)
        #expect(editing.canUndo)

        let session = DocumentSession(
            embeddedSnapshot: baseline,
            viewState: ViewState(selectionPaths: ["/Car/Wheel"], primarySelectionPath: "/Car/Wheel"))
        let restored = EditorDocument.restore(
            session: session, baseline: baseline,
            journal: journal, records: try tail(of: journal))

        // Scene rebuilt: the hide replayed, and undo history is back.
        #expect(restored.snapshot.prim(at: PrimPath("/Car/Body")!)?.visibility == .invisible)
        #expect(restored.canUndo)
        #expect(restored.hasUnsavedChanges)                      // diverged from baseline
        // View state applied.
        #expect(restored.selection.primary == PrimPath("/Car/Wheel")!)
    }

    @Test func restoreWithEmptyWALMatchesBaseline() throws {
        let baseline = sampleSnapshot()
        let session = DocumentSession(embeddedSnapshot: baseline)
        let restored = EditorDocument.restore(
            session: session, baseline: baseline, journal: nil, records: [])
        #expect(restored.hasUnsavedChanges == false)             // nothing to replay
        #expect(restored.canUndo == false)
    }
}
