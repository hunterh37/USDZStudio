import Testing
import Foundation
import USDCore
import EditingKit
@testable import EditorUI

private func p(_ s: String) -> PrimPath { PrimPath(s)! }

@MainActor
private func carDocument() -> EditorDocument {
    let hub = Prim(path: p("/Car/Wheels/FrontLeft/Hub"), typeName: "Mesh")
    let fl = Prim(path: p("/Car/Wheels/FrontLeft"), typeName: "Xform", children: [hub])
    let fr = Prim(path: p("/Car/Wheels/FrontRight"), typeName: "Xform")
    let wheels = Prim(path: p("/Car/Wheels"), typeName: "Xform", children: [fl, fr])
    let body = Prim(path: p("/Car/Body"), typeName: "Mesh")
    let car = Prim(path: p("/Car"), typeName: "Xform", children: [wheels, body])
    let light = Prim(path: p("/Light"), typeName: "SphereLight")
    return EditorDocument(snapshot: StageSnapshot(rootPrims: [car, light]))
}

@MainActor
@Suite("EditorDocument drill-down & breadcrumb")
struct DrillDownDocumentTests {

    @Test func repeatedDrillsDescendToLeaf() {
        let doc = carDocument()
        let leaf = p("/Car/Wheels/FrontLeft/Hub")
        let expected = [p("/Car"), p("/Car/Wheels"), p("/Car/Wheels/FrontLeft"), leaf]
        for step in expected {
            doc.drillInto(leaf)
            #expect(doc.selection.primary == step)
        }
        // Once at the leaf it stays put.
        doc.drillInto(leaf)
        #expect(doc.selection.primary == leaf)
    }

    @Test func drillingRootIsANoOp() {
        let doc = carDocument()
        doc.drillInto(.root)
        #expect(doc.selection.isEmpty)
    }

    @Test func walkUpClimbsAndStopsAtTopLevel() {
        let doc = carDocument()
        doc.selection = Selection([p("/Car/Wheels/FrontLeft")])
        doc.walkUpSelection()
        #expect(doc.selection.primary == p("/Car/Wheels"))
        doc.walkUpSelection()
        #expect(doc.selection.primary == p("/Car"))
        doc.walkUpSelection()   // top-level: no-op
        #expect(doc.selection.primary == p("/Car"))
    }

    @Test func walkUpWithNoSelectionIsANoOp() {
        let doc = carDocument()
        doc.walkUpSelection()
        #expect(doc.selection.isEmpty)
    }

    @Test func breadcrumbTracksSelection() {
        let doc = carDocument()
        #expect(doc.breadcrumb.isEmpty)
        doc.selection = Selection([p("/Car/Wheels/FrontLeft")])
        #expect(doc.breadcrumb.map(\.name) == ["Car", "Wheels", "FrontLeft"])
    }
}

@MainActor
@Suite("EditorDocument part-edit semantics")
struct PartEditDocumentTests {

    @Test func controlsReflectPrimState() {
        let doc = carDocument()
        let controls = doc.partEditControls(for: p("/Car/Body"))
        #expect(controls.map(\.kind) == [.hide, .disable, .delete])
        #expect(controls.first?.title == "Hide")
        #expect(doc.partEditControls(for: p("/Nope")).isEmpty)
    }

    @Test func hideDisableDeleteAreDistinctUndoableEdits() {
        let doc = carDocument()

        doc.performPartEdit(.hide, on: p("/Car/Body"))
        #expect(doc.snapshot.prim(at: p("/Car/Body"))?.visibility == .invisible)
        // Hidden prim still exists in the tree (ships in file).
        #expect(doc.snapshot.prim(at: p("/Car/Body")) != nil)

        doc.performPartEdit(.disable, on: p("/Car/Wheels/FrontRight"))
        #expect(doc.snapshot.prim(at: p("/Car/Wheels/FrontRight"))?.isActive == false)

        doc.selection = Selection([p("/Light")])
        doc.performPartEdit(.delete, on: p("/Light"))
        #expect(doc.snapshot.prim(at: p("/Light")) == nil)
        #expect(doc.selection.isEmpty)      // delete clears the selection

        doc.undo()                          // undo the delete
        #expect(doc.snapshot.prim(at: p("/Light")) != nil)
    }
}

@MainActor
@Suite("EditorDocument isolate mode")
struct IsolateModeDocumentTests {

    @Test func isolateHidesEverythingOffTheSelectedLineage() {
        let doc = carDocument()
        doc.selection = Selection([p("/Car/Wheels/FrontLeft")])
        doc.isolateSelection()
        #expect(doc.isolation.isActive)
        let live = doc.viewportLivePrimPaths
        #expect(live.contains("/Car/Wheels/FrontLeft"))
        #expect(live.contains("/Car/Wheels/FrontLeft/Hub"))
        #expect(live.contains("/Car"))                  // lineage kept
        #expect(!live.contains("/Car/Wheels/FrontRight")) // sibling hidden
        #expect(!live.contains("/Car/Body"))
        #expect(!live.contains("/Light"))
    }

    @Test func isolateNeverDirtiesTheRootLayer() {
        let doc = carDocument()
        let before = doc.snapshot
        doc.selection = Selection([p("/Car/Body")])

        doc.isolateSelection()
        #expect(doc.isolation.isActive)
        #expect(!doc.hasUnsavedChanges)          // the invariant: no dirt
        #expect(doc.snapshot == before)          // stage byte-identical
        #expect(!doc.canUndo)                    // nothing on the command stack

        doc.exitIsolation()
        #expect(!doc.isolation.isActive)
        #expect(!doc.hasUnsavedChanges)
        #expect(doc.snapshot == before)
        // Viewport is back to showing the whole scene.
        #expect(doc.viewportLivePrimPaths == doc.scenePrimPaths)
    }

    @Test func isolateBumpsViewRevisionButNotEditRevision() {
        let doc = carDocument()
        let rev = doc.revision
        let view = doc.viewRevision
        doc.selection = Selection([p("/Car")])
        doc.isolateSelection()
        #expect(doc.revision == rev)                     // edit revision untouched
        #expect(doc.viewRevision == view + 1)            // view revision advanced
        #expect(doc.viewportSceneRevision == doc.revision + doc.viewRevision)
    }

    @Test func toggleFlipsIsolation() {
        let doc = carDocument()
        doc.selection = Selection([p("/Car")])
        doc.toggleIsolation()
        #expect(doc.isolation.isActive)
        doc.toggleIsolation()
        #expect(!doc.isolation.isActive)
    }

    @Test func redundantExitIsANoOp() {
        let doc = carDocument()
        let view = doc.viewRevision
        doc.exitIsolation()               // already inactive
        #expect(doc.viewRevision == view) // guard prevents a spurious bump
    }
}
