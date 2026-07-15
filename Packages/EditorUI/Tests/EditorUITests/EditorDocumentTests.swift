import Testing
import USDCore
import EditingKit
@testable import EditorUI

@MainActor
private func carDocument() -> EditorDocument {
    let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh")
    let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheel])
    return EditorDocument(snapshot: StageSnapshot(rootPrims: [car]))
}

@Suite("EditorDocument")
@MainActor
struct EditorDocumentTests {

    let car = PrimPath("/Car")!
    let wheel = PrimPath("/Car/Wheel")!

    @Test func renameUpdatesSnapshotAndFollowsSelection() {
        let doc = carDocument()
        doc.selection = Selection([wheel])
        doc.rename(wheel, to: "FrontLeft")

        let renamed = PrimPath("/Car/FrontLeft")!
        #expect(doc.snapshot.prim(at: renamed) != nil)
        #expect(doc.snapshot.prim(at: wheel) == nil)
        #expect(doc.selection.primary == renamed)
        #expect(doc.canUndo)
    }

    @Test func renameNoOpsOnBlankOrUnchanged() {
        let doc = carDocument()
        doc.rename(wheel, to: "  ")
        doc.rename(wheel, to: "Wheel")
        #expect(!doc.canUndo)
    }

    @Test func setActiveAndVisibilityAreUndoable() {
        let doc = carDocument()
        doc.setActive(wheel, false)
        #expect(doc.snapshot.prim(at: wheel)?.isActive == false)
        doc.setVisibility(wheel, .invisible)
        #expect(doc.snapshot.prim(at: wheel)?.visibility == .invisible)

        doc.undo()
        #expect(doc.snapshot.prim(at: wheel)?.visibility == .inherited)
        doc.undo()
        #expect(doc.snapshot.prim(at: wheel)?.isActive == true)
        #expect(!doc.canUndo)
    }

    @Test func idempotentEditsDoNotStackHistory() {
        let doc = carDocument()
        doc.setActive(wheel, true)   // already active — no command
        doc.setVisibility(wheel, .inherited)  // already inherited — no command
        #expect(!doc.canUndo)
    }

    @Test func setTransformRoundTripsThroughUndo() {
        let doc = carDocument()
        let trs = TRS(translation: [1, 2, 3], rotationEulerDegrees: [0, 0, 0], scale: [1, 1, 1])
        doc.setTransform(wheel, to: trs, verb: "Move")
        #expect(doc.transform(at: wheel).translation == [1, 2, 3])

        doc.undo()
        #expect(doc.transform(at: wheel).translation == [0, 0, 0])
        doc.redo()
        #expect(doc.transform(at: wheel).translation == [1, 2, 3])
    }

    @Test func transformSnappingApplies() {
        let doc = carDocument()
        doc.snap = SnapSettings(translation: 0.5)
        doc.setTransform(wheel, to: TRS(translation: [0.6, 0.9, 0.2]), verb: "Move")
        #expect(doc.transform(at: wheel).translation == [0.5, 1.0, 0.0])
    }

    @Test func dragSessionCoalescesToOneUndoEntry() {
        let doc = carDocument()
        let session = doc.makeDragSession(for: wheel)
        _ = try? session.translate(by: [1, 0, 0])
        _ = try? session.translate(by: [5, 0, 0])   // live previews, no history yet
        #expect(!doc.canUndo)

        doc.commit(session, verb: "Move")
        #expect(doc.undoLabel == "Move Wheel")
        #expect(doc.transform(at: wheel).translation == [5, 0, 0])

        doc.undo()   // one entry undoes the whole gesture
        #expect(doc.transform(at: wheel).translation == [0, 0, 0])
    }

    @Test func deleteIsUndoableAndClearsSelection() {
        let doc = carDocument()
        doc.selection = Selection([wheel])
        doc.delete(wheel)
        #expect(doc.snapshot.prim(at: wheel) == nil)
        #expect(doc.selection.isEmpty)

        doc.undo()
        #expect(doc.snapshot.prim(at: wheel) != nil)
    }

    @Test func stageMetadataEditsAreUndoable() {
        let doc = carDocument()
        var m = doc.snapshot.metadata
        m.metersPerUnit = 0.01
        m.upAxis = .z
        doc.setStageMetadata(m)
        #expect(doc.snapshot.metadata.metersPerUnit == 0.01)
        #expect(doc.snapshot.metadata.upAxis == .z)

        doc.undo()
        #expect(doc.snapshot.metadata.upAxis == .y)
    }

    @Test func duplicateSelectsTheCopy() {
        let doc = carDocument()
        doc.duplicate(wheel)
        let copy = PrimPath("/Car/Wheel_1")!
        #expect(doc.snapshot.prim(at: copy) != nil)
        #expect(doc.selection.primary == copy)
        doc.undo()
        #expect(doc.snapshot.prim(at: copy) == nil)
    }

    @Test func groupSelectionNestsAndSelectsGroup() {
        let a = Prim(path: PrimPath("/Root/A")!, typeName: "Mesh")
        let b = Prim(path: PrimPath("/Root/B")!, typeName: "Mesh")
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [a, b])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
        doc.selection = Selection([PrimPath("/Root/A")!, PrimPath("/Root/B")!])

        doc.groupSelection()
        #expect(doc.selection.primary == PrimPath("/Root/Group")!)
        #expect(doc.snapshot.prim(at: PrimPath("/Root/Group/A")!) != nil)

        doc.undo()
        #expect(doc.snapshot.prim(at: PrimPath("/Root")!)?.children.map(\.name) == ["A", "B"])
    }

    @Test func revisionAdvancesOnEachChange() {
        let doc = carDocument()
        let start = doc.revision
        doc.setActive(wheel, false)
        doc.undo()
        #expect(doc.revision == start + 2)
    }
}
