import Testing
import Foundation
import simd
import USDCore
import EditingKit
import ViewportKit
@testable import EditorUI

/// A child prim nested under a rotated parent — the case where a world-space
/// gizmo drag must be converted into the child's parent space.
@MainActor
private func makeNestedDocument(parentYawDegrees: Double = 0) -> (EditorDocument, PrimPath) {
    let child = PrimPath("/Rig/Panel")!
    let panel = Prim(path: child, typeName: "Xform")
    var rig = Prim(path: PrimPath("/Rig")!, typeName: "Xform", children: [panel])
    if parentYawDegrees != 0 {
        let trs = TRS(rotationEulerDegrees: [0, parentYawDegrees, 0])
        rig = Prim(path: rig.path, typeName: rig.typeName,
                   attributes: [Attribute(name: transformAttributeName,
                                          value: .matrix4(trs.toMatrix()))],
                   children: [panel])
    }
    return (EditorDocument(snapshot: StageSnapshot(rootPrims: [rig])), child)
}

@MainActor
@Suite("Translate gizmo — descriptor (EditorDocument)")
struct TranslateGizmoDescriptorTests {

    @Test func hiddenWithNoSelection() {
        let (doc, _) = makeNestedDocument()
        #expect(doc.translateGizmo == nil)
    }

    @Test func shownAtSelectedPrimWorldPivot() {
        let (doc, child) = makeNestedDocument()
        doc.setTransform(child, to: TRS(translation: [1, 2, 3]), verb: "Move")
        doc.selection = Selection([child])
        let gizmo = doc.translateGizmo
        #expect(gizmo != nil)
        #expect(gizmo?.origin == SIMD3(1, 2, 3))
    }

    @Test func hiddenForDeletedPrim() {
        let (doc, child) = makeNestedDocument()
        doc.selection = Selection([child])
        doc.delete(child)
        #expect(doc.translateGizmo == nil)
    }

    @Test func originFollowsDragLive() {
        let (doc, child) = makeNestedDocument()
        doc.selection = Selection([child])
        doc.handleTranslateGizmoDrag(.began(.x))
        doc.handleTranslateGizmoDrag(.changed(.x, 2.5))
        #expect(doc.translateGizmo?.origin == SIMD3(2.5, 0, 0))
        doc.handleTranslateGizmoDrag(.ended)
    }
}

@MainActor
@Suite("Translate gizmo — drag (EditorDocument)")
struct TranslateGizmoDragTests {

    @Test func dragTranslatesAlongWorldAxis() {
        let (doc, child) = makeNestedDocument()
        doc.selection = Selection([child])
        doc.handleTranslateGizmoDrag(.began(.y))
        doc.handleTranslateGizmoDrag(.changed(.y, 1.25))
        doc.handleTranslateGizmoDrag(.ended)
        #expect(doc.transform(at: child).translation == [0, 1.25, 0])
    }

    @Test func dragCoalescesIntoOneUndoEntry() {
        let (doc, child) = makeNestedDocument()
        doc.selection = Selection([child])
        doc.handleTranslateGizmoDrag(.began(.x))
        for step in 1...5 {
            doc.handleTranslateGizmoDrag(.changed(.x, Double(step) * 0.2))
        }
        doc.handleTranslateGizmoDrag(.ended)
        #expect(doc.transform(at: child).translation[0] == 1.0)
        #expect(doc.undoLabel == "Move Panel")
        doc.undo()
        #expect(doc.transform(at: child).translation == [0, 0, 0])
        #expect(doc.canUndo == false)
    }

    @Test func worldDeltaIsConvertedIntoRotatedParentSpace() {
        // Parent yawed 90° about +Y: world +X is the child's local -Z
        // (row-vector convention). A world-X drag must land there.
        let (doc, child) = makeNestedDocument(parentYawDegrees: 90)
        doc.selection = Selection([child])
        doc.handleTranslateGizmoDrag(.began(.x))
        doc.handleTranslateGizmoDrag(.changed(.x, 2))
        doc.handleTranslateGizmoDrag(.ended)
        let t = doc.transform(at: child).translation
        #expect(abs(t[0]) < 1e-9)
        #expect(abs(t[1]) < 1e-9)
        #expect(abs(abs(t[2]) - 2) < 1e-9)
        // And the world position actually moved along +X.
        let world = doc.snapshot.worldMatrix(at: child)
        #expect(abs(world[12] - 2) < 1e-9)
        #expect(abs(world[14]) < 1e-9)
    }

    @Test func zeroDragCommitsNothing() {
        let (doc, child) = makeNestedDocument()
        doc.selection = Selection([child])
        doc.handleTranslateGizmoDrag(.began(.z))
        doc.handleTranslateGizmoDrag(.ended)
        #expect(doc.canUndo == false)
    }

    @Test func multiSelectionMovesTogetherAsOneUndo() {
        let a = Prim(path: PrimPath("/A")!, typeName: "Xform")
        let b = Prim(path: PrimPath("/B")!, typeName: "Xform")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [a, b]))
        doc.selection = Selection([a.path, b.path])
        doc.handleTranslateGizmoDrag(.began(.x))
        doc.handleTranslateGizmoDrag(.changed(.x, 1))
        doc.handleTranslateGizmoDrag(.ended)
        #expect(doc.transform(at: a.path).translation[0] == 1)
        #expect(doc.transform(at: b.path).translation[0] == 1)
        doc.undo()
        #expect(doc.transform(at: a.path).translation[0] == 0)
        #expect(doc.transform(at: b.path).translation[0] == 0)
        #expect(doc.canUndo == false)
    }

    @Test func namedAxisDragHelperDrivesFullGesture() {
        let (doc, child) = makeNestedDocument()
        doc.selection = Selection([child])
        #expect(doc.translateGizmoOrigin == [0, 0, 0])
        #expect(doc.performTranslateGizmoDrag(axis: "Y", distance: 2) == true)
        #expect(doc.transform(at: child).translation == [0, 2, 0])
        #expect(doc.translateGizmoOrigin == [0, 2, 0])
        #expect(doc.undoLabel == "Move Panel")
    }

    @Test func namedAxisDragHelperRefusesBadInput() {
        let (doc, child) = makeNestedDocument()
        // Hidden gizmo (no selection): refused.
        #expect(doc.performTranslateGizmoDrag(axis: "x", distance: 1) == false)
        #expect(doc.translateGizmoOrigin == nil)
        // Unknown axis: refused, nothing moves.
        doc.selection = Selection([child])
        #expect(doc.performTranslateGizmoDrag(axis: "w", distance: 1) == false)
        #expect(doc.transform(at: child).translation == [0, 0, 0])
        #expect(doc.canUndo == false)
    }

    @Test func snappingAppliesDuringDrag() {
        let (doc, child) = makeNestedDocument()
        doc.snap = SnapSettings(translation: 0.5)
        doc.selection = Selection([child])
        doc.handleTranslateGizmoDrag(.began(.x))
        doc.handleTranslateGizmoDrag(.changed(.x, 0.6))
        doc.handleTranslateGizmoDrag(.ended)
        #expect(doc.transform(at: child).translation[0] == 0.5)
    }
}

@MainActor
@Suite("Viewport live transforms (EditorDocument)")
struct ViewportLiveTransformTests {

    @Test func authoredTransformsAppearColumnMajor() {
        let (doc, child) = makeNestedDocument()
        doc.setTransform(child, to: TRS(translation: [1, 2, 3]), verb: "Move")
        let live = doc.viewportLiveTransforms
        let m = live[child.description]
        #expect(m != nil)
        // Translation lands in column 3 (RealityKit column-vector convention).
        #expect(m?.columns.3 == SIMD4<Float>(1, 2, 3, 1))
    }

    @Test func primsWithoutTransformsAreOmitted() {
        let (doc, child) = makeNestedDocument()
        #expect(doc.viewportLiveTransforms[child.description] == nil)
    }

    @Test func undoRefreshesLiveTransforms() {
        let (doc, child) = makeNestedDocument()
        doc.setTransform(child, to: TRS(translation: [4, 0, 0]), verb: "Move")
        #expect(doc.viewportLiveTransforms[child.description]?.columns.3.x == 4)
        doc.undo()
        // Undo restores an identity op (no removeAttribute yet), so the entry
        // remains but reads identity.
        #expect(doc.viewportLiveTransforms[child.description]?.columns.3.x == 0)
    }
}
