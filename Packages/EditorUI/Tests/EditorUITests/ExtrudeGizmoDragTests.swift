import Testing
import Foundation
import simd
import USDCore
import MeshKit
import ViewportKit
@testable import EditorUI

/// Single unit quad in the XY plane (normal +Z), the standard mesh-edit fixture.
@MainActor
private func makeQuadDocument() -> (EditorDocument, PrimPath) {
    let path = PrimPath("/Root/Panel")!
    let mesh = Prim(
        path: path, typeName: "Mesh",
        attributes: [
            Attribute(name: "points",
                      value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([4])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3])),
        ])
    let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
    let document = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
    document.enterMeshEditMode(at: path)
    return (document, path)
}

/// Two coplanar quads sharing an edge (both normals +Z) — multi-face region.
@MainActor
private func makeTwoQuadDocument() -> EditorDocument {
    let path = PrimPath("/Root/Panel")!
    let mesh = Prim(
        path: path, typeName: "Mesh",
        attributes: [
            Attribute(name: "points",
                      value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0,
                                           2, 0, 0, 2, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([4, 4])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3, 1, 4, 5, 2])),
        ])
    let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
    let document = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
    document.enterMeshEditMode(at: path)
    return document
}

/// Max |z| of the currently selected faces' vertices — where the drag put the cap.
@MainActor
private func selectedCapZ(_ doc: EditorDocument) -> Double {
    guard let state = doc.meshEdit, case .faces(let faces) = state.componentSelection
    else { return .nan }
    let mesh = state.session.mesh
    var z = 0.0
    for f in faces {
        for v in mesh.faceLoops[f] ?? [] { z = abs(mesh.positions[v]!.z) > abs(z) ? mesh.positions[v]!.z : z }
    }
    return z
}

@MainActor
@Suite("Extrude gizmo — descriptor (EditorDocument)")
struct ExtrudeGizmoDescriptorTests {

    @Test func descriptorAnchorsAtCentroidAlongNormal() {
        let (doc, _) = makeQuadDocument()
        let gizmo = doc.meshEditExtrudeGizmo
        #expect(gizmo != nil)
        #expect(simd_length(gizmo!.origin - SIMD3(0.5, 0.5, 0)) < 1e-9)
        #expect(simd_length(gizmo!.axis - SIMD3(0, 0, 1)) < 1e-9)
    }

    @Test func descriptorAveragesMultiFaceSelection() {
        let doc = makeTwoQuadDocument()
        doc.selectMeshFace(index: nil) // both faces
        let gizmo = doc.meshEditExtrudeGizmo
        #expect(gizmo != nil)
        #expect(simd_length(gizmo!.origin - SIMD3(1, 0.5, 0)) < 1e-9)
        #expect(simd_length(gizmo!.axis - SIMD3(0, 0, 1)) < 1e-9)
    }

    @Test func noDescriptorOutsideFaceMode() {
        let (doc, _) = makeQuadDocument()
        doc.meshEdit?.mode = .edge
        #expect(doc.meshEditExtrudeGizmo == nil)
    }

    @Test func noDescriptorWithEmptySelection() {
        let (doc, _) = makeQuadDocument()
        doc.meshEdit?.componentSelection = .faces([])
        #expect(doc.meshEditExtrudeGizmo == nil)
    }

    @Test func noDescriptorOutsideEditMode() {
        let (doc, _) = makeQuadDocument()
        doc.exitMeshEditMode(commit: false)
        #expect(doc.meshEditExtrudeGizmo == nil)
    }

    @Test func descriptorFollowsThePreviewCap() {
        // Mid-drag the handle re-anchors to the lifted cap (like Blender),
        // while the drag itself measures against the frozen start axis.
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(0.4))
        let gizmo = doc.meshEditExtrudeGizmo
        #expect(abs(gizmo!.origin.z - 0.4) < 1e-9)
        #expect(doc.meshEdit?.gizmoDrag?.axis == SIMD3(0, 0, 1))
    }
}

@MainActor
@Suite("Extrude gizmo — drag lifecycle (EditorDocument)")
struct ExtrudeGizmoDragTests {

    @Test func dragExtrudesLiveAndCommitsLastDistance() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        #expect(doc.meshEdit?.gizmoDrag != nil)

        doc.handleExtrudeGizmoDrag(.changed(0.5))
        #expect(doc.meshEdit?.session.mesh.faceCount == 5) // live preview
        #expect(abs(selectedCapZ(doc) - 0.5) < 1e-9)

        doc.handleExtrudeGizmoDrag(.changed(0.3)) // scrub back down
        #expect(doc.meshEdit?.session.mesh.faceCount == 5) // still ONE extrude
        #expect(abs(selectedCapZ(doc) - 0.3) < 1e-9)

        doc.handleExtrudeGizmoDrag(.ended)
        #expect(doc.meshEdit?.gizmoDrag == nil)
        #expect(doc.meshEdit?.session.journal.count == 1) // one undo step per drag
        #expect(doc.meshEdit?.session.isDirty == true)
        // HUD stays in sync: ⏎ would repeat exactly what was dragged.
        #expect(abs((doc.meshEdit?.extrudeDistance ?? 0) - 0.3) < 1e-9)
    }

    @Test func dragBackToZeroLeavesSessionClean() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(0.5))
        doc.handleExtrudeGizmoDrag(.changed(0.0))
        doc.handleExtrudeGizmoDrag(.ended)
        #expect(doc.meshEdit?.session.isDirty == false)
        #expect(doc.meshEdit?.session.mesh.faceCount == 1)
    }

    @Test func grabWithoutMovingIsANoOp() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.ended)
        #expect(doc.meshEdit?.session.isDirty == false)
        #expect(doc.meshEdit?.gizmoDrag == nil)
    }

    @Test func negativeDragExtrudesInward() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(-0.4))
        doc.handleExtrudeGizmoDrag(.ended)
        #expect(doc.meshEdit?.session.mesh.faceCount == 5)
        #expect(abs(selectedCapZ(doc) + 0.4) < 1e-9)
    }

    @Test func multiFaceRegionDragsAsOneUnit() {
        let doc = makeTwoQuadDocument()
        doc.selectMeshFace(index: nil)
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(0.25))
        doc.handleExtrudeGizmoDrag(.ended)
        // Region extrude: 2 caps + 6 boundary side quads.
        #expect(doc.meshEdit?.session.mesh.faceCount == 8)
        #expect(abs(selectedCapZ(doc) - 0.25) < 1e-9)
        #expect(doc.meshEdit?.session.journal.count == 1)
    }

    @Test func consecutiveDragsChainOnTheCap() {
        let (doc, _) = makeQuadDocument()
        for distance in [0.2, 0.3] {
            doc.handleExtrudeGizmoDrag(.began)
            doc.handleExtrudeGizmoDrag(.changed(distance))
            doc.handleExtrudeGizmoDrag(.ended)
        }
        #expect(doc.meshEdit?.session.mesh.faceCount == 9) // two stacked extrudes
        #expect(abs(selectedCapZ(doc) - 0.5) < 1e-9)       // 0.2 + 0.3
        #expect(doc.meshEdit?.session.journal.count == 2)  // one step per drag
    }

    @Test func inSessionUndoRewindsOneWholeDrag() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(0.5))
        doc.handleExtrudeGizmoDrag(.ended)
        doc.undoMeshEdit()
        #expect(doc.meshEdit?.session.mesh.faceCount == 1)
        #expect(doc.meshEdit?.session.isDirty == false)
    }

    @Test func commitFlushesDragAsOneUndoableCommand() {
        let (doc, path) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(0.5))
        doc.handleExtrudeGizmoDrag(.ended)
        doc.exitMeshEditMode(commit: true)
        guard case .intArray(let counts)? =
            doc.snapshot.prim(at: path)?.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("counts not flushed"); return
        }
        #expect(counts == [4, 4, 4, 4, 4])
        #expect(doc.canUndo)
        doc.undo()
        guard case .intArray(let restored)? =
            doc.snapshot.prim(at: path)?.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("counts missing after undo"); return
        }
        #expect(restored == [4])
    }

    @Test func changedWithoutBeganIsIgnored() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.changed(0.5))
        #expect(doc.meshEdit?.session.isDirty == false)
        #expect(doc.meshEdit?.session.mesh.faceCount == 1)
    }

    @Test func beganWithEmptySelectionIsIgnored() {
        let (doc, _) = makeQuadDocument()
        doc.meshEdit?.componentSelection = .faces([])
        doc.handleExtrudeGizmoDrag(.began)
        #expect(doc.meshEdit?.gizmoDrag == nil)
    }

    @Test func secondBeganDuringDragIsIgnored() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(0.5))
        doc.handleExtrudeGizmoDrag(.began) // must not reset the live drag
        #expect(abs((doc.meshEdit?.gizmoDrag?.distance ?? 0) - 0.5) < 1e-9)
        #expect(doc.meshEdit?.session.mesh.faceCount == 5)
    }

    @Test func subThresholdWiggleStaysClean() {
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(1e-9))
        #expect(doc.meshEdit?.session.isDirty == false)
        doc.handleExtrudeGizmoDrag(.ended)
        #expect(doc.meshEdit?.session.isDirty == false)
    }

    @Test func buttonToolStillWorksAfterDrag() {
        // The two input paths coexist: drag, then E+⏎ on the new cap.
        let (doc, _) = makeQuadDocument()
        doc.handleExtrudeGizmoDrag(.began)
        doc.handleExtrudeGizmoDrag(.changed(0.5))
        doc.handleExtrudeGizmoDrag(.ended)
        doc.meshEdit?.tool = .extrude
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic == nil)
        #expect(doc.meshEdit?.session.mesh.faceCount == 9)
    }
}
