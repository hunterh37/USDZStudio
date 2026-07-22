import Testing
import Foundation
import simd
import USDCore
import EditingKit
import ViewportKit
@testable import EditorUI

@MainActor
private func makeDoc(_ prims: [Prim]) -> EditorDocument {
    EditorDocument(snapshot: StageSnapshot(rootPrims: prims))
}

private func xform(_ path: String) -> Prim { Prim(path: PrimPath(path)!, typeName: "Xform") }
private func approx(_ a: Double, _ b: Double, tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@MainActor
@Suite("Modal transform — EditorDocument integration")
struct ModalTransformDocumentTests {

    @Test func beginRequiresSelection() {
        let doc = makeDoc([xform("/A")])
        #expect(doc.beginModalTransform(kind: .grab) == false)   // nothing selected
        doc.selection = Selection([PrimPath("/A")!])
        #expect(doc.beginModalTransform(kind: .grab))
        #expect(doc.modalTransform?.kind == .grab)
    }

    @Test func doubleBeginIsRejected() {
        let doc = makeDoc([xform("/A")])
        doc.selection = Selection([PrimPath("/A")!])
        #expect(doc.beginModalTransform(kind: .grab))
        #expect(doc.beginModalTransform(kind: .rotate) == false)
    }

    @Test func grabConfirmCoalescesToOneMove() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        #expect(doc.beginModalTransform(kind: .grab))
        doc.updateModalTransform(.translate(SIMD3(2, 0, 3)))
        doc.confirmModalTransform()
        #expect(doc.modalTransform == nil)
        let t = doc.transform(at: a).translation
        #expect(approx(t[0], 2) && approx(t[1], 0) && approx(t[2], 3))
        #expect(doc.undoLabel == "Move A")
        doc.undo()
        let back = doc.transform(at: a).translation
        #expect(approx(back[0], 0) && approx(back[2], 0))
        #expect(doc.canUndo == false)      // exactly one entry
    }

    @Test func cancelRestoresAndEmitsNothing() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        #expect(doc.beginModalTransform(kind: .grab))
        doc.updateModalTransform(.translate(SIMD3(5, 5, 5)))  // live preview
        doc.cancelModalTransform()
        #expect(doc.modalTransform == nil)
        let t = doc.transform(at: a).translation
        #expect(approx(t[0], 0) && approx(t[1], 0) && approx(t[2], 0))
        #expect(doc.canUndo == false)      // nothing recorded
    }

    @Test func rotateConfirmMatchesGizmoRotate() {
        // A modal rotate about world Z by 42° must match the handle-gizmo path.
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        #expect(doc.beginModalTransform(kind: .rotate))
        doc.updateModalTransform(.rotate(axis: SIMD3(0, 0, 1), degrees: 42))
        doc.confirmModalTransform()

        let other = makeDoc([xform("/A")])
        other.selection = Selection([a])
        other.gizmoMode = .rotate
        #expect(other.performRotateGizmoDrag(axis: "z", degrees: 42))
        for i in 0..<3 {
            #expect(approx(doc.transform(at: a).rotationEulerDegrees[i],
                           other.transform(at: a).rotationEulerDegrees[i], tol: 1e-4))
        }
        #expect(doc.undoLabel == "Rotate A")
    }

    @Test func scaleUniformAboutPivot() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        #expect(doc.beginModalTransform(kind: .scale))
        doc.updateModalTransform(.scale(basis: .world, factors: SIMD3(2, 2, 2)))
        doc.confirmModalTransform()
        let s = doc.transform(at: a).scale
        #expect(approx(s[0], 2) && approx(s[1], 2) && approx(s[2], 2))
        #expect(doc.undoLabel == "Scale A")
    }

    @Test func axisScaleAffectsOnlyOneAxis() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        #expect(doc.beginModalTransform(kind: .scale))
        doc.updateModalTransform(.scale(basis: .world, factors: SIMD3(1, 3, 1)))
        doc.confirmModalTransform()
        let s = doc.transform(at: a).scale
        #expect(approx(s[0], 1) && approx(s[1], 3) && approx(s[2], 1))
    }

    @Test func constraintAndNumericForwardToSession() {
        let doc = makeDoc([xform("/A")])
        doc.selection = Selection([PrimPath("/A")!])
        #expect(doc.beginModalTransform(kind: .grab))
        doc.modalSetConstraint(axis: .z, shift: false)
        doc.modalTypeDigit("2"); doc.modalTypeDigit("."); doc.modalTypeDigit("4")
        #expect(doc.modalTransform?.hudText == "Move Z: 2.4 (global)")
        doc.modalBackspaceNumeric()
        #expect(doc.modalTransform?.hudText == "Move Z: 2. (global)")
    }

    @Test func updateAndConfirmAreNoOpsWithoutSession() {
        let doc = makeDoc([xform("/A")])
        doc.updateModalTransform(.translate(SIMD3(1, 1, 1)))   // no crash, no change
        doc.confirmModalTransform()
        doc.cancelModalTransform()
        doc.modalSetConstraint(axis: .x, shift: true)
        doc.modalTypeDigit("9")
        #expect(doc.modalTransform == nil)
        #expect(doc.canUndo == false)
    }

    @Test func noModalOnEmptySelectionAfterMeshEditGuard() {
        let doc = makeDoc([xform("/A")])
        doc.selection = Selection([PrimPath("/A")!])
        #expect(doc.beginModalTransform(kind: .grab))
        doc.cancelModalTransform()
        #expect(doc.beginModalTransform(kind: .rotate))  // can start again after cancel
        doc.cancelModalTransform()
    }

    @Test func basisScaleMatrixReducesToDiagonalForWorld() {
        let m = EditorDocument.basisScaleMatrix(basis: .world, factors: [2, 3, 4])
        #expect(approx(m[0], 2) && approx(m[5], 3) && approx(m[10], 4) && approx(m[15], 1))
        // Off-diagonal linear terms are zero for the world basis.
        #expect(approx(m[1], 0) && approx(m[4], 0) && approx(m[9], 0))
    }

    @Test func matrixForTranslateOp() {
        let m = EditorDocument.matrix(for: .translate(SIMD3(1, 2, 3)))
        #expect(approx(m[12], 1) && approx(m[13], 2) && approx(m[14], 3))
    }
}
