import Testing
import Foundation
import USDCore
@testable import EditorUI

@MainActor
@Suite("EditorDocument — console edits + export compliance")
struct EditorDocumentConsoleTests {

    private func doc(_ prims: [Prim] = [Prim(path: PrimPath("/Root")!, typeName: "Xform")],
                     metadata: StageMetadata = StageMetadata()) -> EditorDocument {
        EditorDocument(snapshot: StageSnapshot(metadata: metadata, rootPrims: prims))
    }

    @Test func applyConsoleEditPushesUndoableCommandWhenChanged() {
        let document = doc()
        let after = StageSnapshot(rootPrims: [
            Prim(path: PrimPath("/Root")!, typeName: "Xform"),
            Prim(path: PrimPath("/Added")!, typeName: "Mesh")])

        #expect(document.applyConsoleEdit(after: after, label: "Console: edit") == true)
        #expect(document.snapshot.rootPrims.map(\.path.name) == ["Root", "Added"])
        #expect(document.canUndo)
        #expect(document.undoLabel == "Console: edit")

        document.undo()
        #expect(document.snapshot.rootPrims.map(\.path.name) == ["Root"])
    }

    @Test func applyConsoleEditIsNoOpWhenUnchanged() {
        let document = doc()
        // Same content, only a different sourceURL — must not push a command.
        let same = StageSnapshot(sourceURL: URL(fileURLWithPath: "/tmp/x.usda"),
                                 rootPrims: [Prim(path: PrimPath("/Root")!, typeName: "Xform")])
        #expect(document.applyConsoleEdit(after: same, label: "Console: noop") == false)
        #expect(document.canUndo == false)
    }

    @Test func exportComplianceAllowsCleanStage() {
        // A `defaultPrim` is required for export since #172 — AR QuickLook
        // cannot pick a root prim without one — so a genuinely clean stage
        // declares it.
        let clean = StageSnapshot(
            metadata: StageMetadata(defaultPrim: "Root"),
            rootPrims: [Prim(path: PrimPath("/Root")!, typeName: "Xform")])
        #expect(EditorDocument(snapshot: clean).exportCompliance().isExportAllowed)
    }

    @Test func exportComplianceBlocksOnError() {
        // defaultPrim naming a non-existent prim is an ARKit-blocking error.
        let document = doc(metadata: StageMetadata(defaultPrim: "Ghost"))
        let result = document.exportCompliance()
        #expect(result.isExportAllowed == false)
        #expect(result.blockingDiagnostics.isEmpty == false)
    }
}
