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
@Suite("Rotate gizmo — descriptor + drag (EditorDocument)")
struct RotateGizmoDocumentTests {

    @Test func hiddenUnlessRotateModeSelected() {
        let doc = makeDoc([xform("/A")])
        doc.selection = Selection([PrimPath("/A")!])
        #expect(doc.rotateGizmo == nil)          // default mode is translate
        doc.gizmoMode = .rotate
        #expect(doc.rotateGizmo != nil)
        #expect(doc.translateGizmo == nil)       // only the active gizmo shows
    }

    @Test func dragRotatesAboutZAndCoalesces() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        doc.gizmoMode = .rotate
        doc.handleRotateGizmoDrag(.began(.z))
        for step in 1...3 { doc.handleRotateGizmoDrag(.changed(.z, Double(step) * 30)) }
        doc.handleRotateGizmoDrag(.ended)
        #expect(approx(doc.transform(at: a).rotationEulerDegrees[2], 90))
        #expect(doc.undoLabel == "Rotate A")
        doc.undo()
        #expect(approx(doc.transform(at: a).rotationEulerDegrees[2], 0))
        #expect(doc.canUndo == false)
    }

    @Test func matchesTransformDragSessionParity() throws {
        // Document rotate of a root prim must match a direct session rotate.
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        doc.gizmoMode = .rotate
        #expect(doc.performRotateGizmoDrag(axis: "z", degrees: 42))

        let stage = InMemoryStage(StageSnapshot(rootPrims: [xform("/A")]))
        let session = TransformDragSession(stage: stage, path: a)
        try session.rotate(byDegrees: [0, 0, 42])
        let expected = session.currentTRS.rotationEulerDegrees
        let got = doc.transform(at: a).rotationEulerDegrees
        for i in 0..<3 { #expect(approx(got[i], expected[i])) }
    }

    @Test func multiSelectRotatesAboutSharedMedianPivot() {
        // Two prims at x=±1; a 180° yaw about the shared median (origin) swaps
        // their world positions.
        let a = Prim(path: PrimPath("/A")!, typeName: "Xform",
                     attributes: [Attribute(name: transformAttributeName,
                                            value: .matrix4(TRS(translation: [1, 0, 0]).toMatrix()))])
        let b = Prim(path: PrimPath("/B")!, typeName: "Xform",
                     attributes: [Attribute(name: transformAttributeName,
                                            value: .matrix4(TRS(translation: [-1, 0, 0]).toMatrix()))])
        let doc = makeDoc([a, b])
        doc.selection = Selection([a.path, b.path])
        doc.gizmoMode = .rotate
        #expect(doc.rotateGizmoOrigin == [0, 0, 0])
        doc.performRotateGizmoDrag(axis: "y", degrees: 180)
        let wa = doc.snapshot.worldMatrix(at: a.path)
        #expect(approx(wa[12], -1) && approx(wa[14], 0, tol: 1e-6))
        #expect(doc.undoLabel == "Rotate 2 prims")
    }

    @Test func angleSnappingApplies() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.snap = SnapSettings(rotationDegrees: 45)
        doc.selection = Selection([a])
        doc.gizmoMode = .rotate
        doc.performRotateGizmoDrag(axis: "z", degrees: 50)   // snaps to 45
        #expect(approx(doc.transform(at: a).rotationEulerDegrees[2], 45))
    }

    @Test func performRefusesWhenHiddenOrBadAxis() {
        let doc = makeDoc([xform("/A")])
        #expect(doc.performRotateGizmoDrag(axis: "z", degrees: 10) == false) // no selection
        doc.selection = Selection([PrimPath("/A")!])
        doc.gizmoMode = .rotate
        #expect(doc.performRotateGizmoDrag(axis: "w", degrees: 10) == false) // bad axis
        #expect(doc.canUndo == false)
    }
}

@MainActor
@Suite("Scale gizmo — descriptor + drag (EditorDocument)")
struct ScaleGizmoDocumentTests {

    @Test func hiddenUnlessScaleModeSelected() {
        let doc = makeDoc([xform("/A")])
        doc.selection = Selection([PrimPath("/A")!])
        #expect(doc.scaleGizmo == nil)
        doc.gizmoMode = .scale
        #expect(doc.scaleGizmo != nil)
    }

    @Test func uniformHandleScalesAllAxes() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        doc.gizmoMode = .scale
        doc.performScaleGizmoDrag(handle: "uniform", factor: 2)
        let s = doc.transform(at: a).scale
        #expect(approx(s[0], 2) && approx(s[1], 2) && approx(s[2], 2))
        #expect(doc.undoLabel == "Scale A")
    }

    @Test func perAxisHandleScalesOnlyThatAxis() {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        doc.gizmoMode = .scale
        doc.performScaleGizmoDrag(handle: "x", factor: 3)
        let s = doc.transform(at: a).scale
        #expect(approx(s[0], 3) && approx(s[1], 1) && approx(s[2], 1))
    }

    @Test func perAxisScaleParityWithSession() throws {
        let doc = makeDoc([xform("/A")])
        let a = PrimPath("/A")!
        doc.selection = Selection([a])
        doc.gizmoMode = .scale
        doc.performScaleGizmoDrag(handle: "y", factor: 2.5)

        let stage = InMemoryStage(StageSnapshot(rootPrims: [xform("/A")]))
        let session = TransformDragSession(stage: stage, path: a)
        try session.scale(byPerAxis: [1, 2.5, 1])
        #expect(doc.transform(at: a).scale == session.currentTRS.scale)
    }

    @Test func uniformScaleAboutMedianMovesOffPivotPrims() {
        // A prim at x=2, pivot at median (its own origin for single select)
        // stays put; add a second prim so the median sits between them.
        let a = Prim(path: PrimPath("/A")!, typeName: "Xform",
                     attributes: [Attribute(name: transformAttributeName,
                                            value: .matrix4(TRS(translation: [2, 0, 0]).toMatrix()))])
        let b = xform("/B") // at origin
        let doc = makeDoc([a, b])
        doc.selection = Selection([a.path, b.path])
        doc.gizmoMode = .scale
        #expect(doc.scaleGizmoOrigin == [1, 0, 0]) // median of (2,0,0) and (0,0,0)
        doc.performScaleGizmoDrag(handle: "uniform", factor: 2)
        // A doubles distance from pivot: 2 → 3 in world x.
        let wa = doc.snapshot.worldMatrix(at: a.path)
        #expect(approx(wa[12], 3))
        #expect(doc.undoLabel == "Scale 2 prims")
    }

    @Test func performRefusesBadHandle() {
        let doc = makeDoc([xform("/A")])
        doc.selection = Selection([PrimPath("/A")!])
        doc.gizmoMode = .scale
        #expect(doc.performScaleGizmoDrag(handle: "diagonal", factor: 2) == false)
        #expect(doc.canUndo == false)
    }
}
