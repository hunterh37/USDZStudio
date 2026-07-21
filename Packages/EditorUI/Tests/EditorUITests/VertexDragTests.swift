import Testing
import Foundation
import simd
import USDCore
import MeshKit
import ViewportKit
@testable import EditorUI

/// A 2×2 quad grid in the XY plane (9 vertices, 4 quads) — enough topology for
/// proportional falloff to reach interior neighbors.
@MainActor
private func makeGridDocument() -> (EditorDocument, PrimPath) {
    let path = PrimPath("/Root/Panel")!
    var points: [Double] = []
    for y in 0...2 { for x in 0...2 { points += [Double(x), Double(y), 0] } }
    var counts: [Int] = [], indices: [Int] = []
    for y in 0..<2 {
        for x in 0..<2 {
            counts.append(4)
            let w = 3
            indices += [y * w + x, y * w + x + 1, (y + 1) * w + x + 1, (y + 1) * w + x]
        }
    }
    let mesh = Prim(
        path: path, typeName: "Mesh",
        attributes: [
            Attribute(name: "points", value: .float3Array(points)),
            Attribute(name: "faceVertexCounts", value: .intArray(counts)),
            Attribute(name: "faceVertexIndices", value: .intArray(indices)),
        ])
    let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
    let document = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
    document.enterMeshEditMode(at: path)
    document.meshEdit?.mode = .vertex
    return (document, path)
}

@MainActor
private func position(_ doc: EditorDocument, _ index: Int) -> SIMD3<Double> {
    let mesh = doc.meshEdit!.session.mesh
    return mesh.positions[mesh.vertexOrder[index]]!
}

@MainActor
@Suite("Live vertex drag (EditorDocument)")
struct VertexDragTests {

    @Test func selectingAndRigidDraggingMovesOnlyTheGrabbedVertex() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 0)               // corner (0,0,0)
        doc.beginVertexDrag()
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        doc.endVertexDrag()

        #expect(simd_length(position(doc, 0) - SIMD3(0, 0, 1)) < 1e-9)
        #expect(simd_length(position(doc, 8) - SIMD3(2, 2, 0)) < 1e-9) // far corner untouched
        #expect(doc.meshEdit?.session.journal.count == 1)              // one undo step
        #expect(doc.meshEdit?.vertexDrag == nil)
    }

    @Test func proportionalFalloffDragsNeighborsPartially() {
        let (doc, _) = makeGridDocument()
        doc.meshEdit?.proportionalRadius = 1.5
        doc.meshEdit?.proportionalCurve = .linear
        doc.selectMeshVertex(index: 0)               // corner seed
        doc.beginVertexDrag()
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        doc.endVertexDrag()

        // Seed moves fully; an edge-neighbor at distance 1 (weight 1-1/1.5) moves partially.
        #expect(abs(position(doc, 0).z - 1) < 1e-9)
        let neighborZ = position(doc, 1).z          // (1,0,0), one edge away
        #expect(neighborZ > 0.2 && neighborZ < 0.9)
        #expect(abs(position(doc, 8).z) < 1e-9)      // beyond the radius: unmoved
    }

    @Test func scrubbingKeepsExactlyOneOp() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 4)               // center vertex
        doc.beginVertexDrag()
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        doc.updateVertexDrag(translation: SIMD3(0, 0, 0.3)) // scrub back
        doc.endVertexDrag()
        #expect(abs(position(doc, 4).z - 0.3) < 1e-9)
        #expect(doc.meshEdit?.session.journal.count == 1)   // still one op
    }

    @Test func dragBackToZeroLeavesSessionClean() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 0)
        doc.beginVertexDrag()
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        doc.updateVertexDrag(translation: .zero)
        doc.endVertexDrag()
        #expect(doc.meshEdit?.session.isDirty == false)
    }

    @Test func grabWithoutMovingIsANoOp() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 0)
        doc.beginVertexDrag()
        doc.endVertexDrag()
        #expect(doc.meshEdit?.session.isDirty == false)
        #expect(doc.meshEdit?.vertexDrag == nil)
    }

    @Test func beginWithNoSelectionReportsAndDoesNotDrag() {
        let (doc, _) = makeGridDocument()
        doc.meshEdit?.componentSelection = .vertices([])
        doc.beginVertexDrag()
        #expect(doc.meshEdit?.vertexDrag == nil)
        #expect(doc.meshEdit?.lastDiagnostic != nil)
    }

    @Test func seedIndexShortcutSelectsAndDrags() {
        let (doc, _) = makeGridDocument()
        doc.beginVertexDrag(seedIndex: 2)            // grab without a prior click
        doc.updateVertexDrag(translation: SIMD3(0, 0, 0.5))
        doc.endVertexDrag()
        #expect(abs(position(doc, 2).z - 0.5) < 1e-9)
    }

    @Test func changedWithoutBeganIsIgnored() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 0)
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        #expect(doc.meshEdit?.session.isDirty == false)
    }

    @Test func secondBeginDuringDragIsIgnored() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 0)
        doc.beginVertexDrag()
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        doc.beginVertexDrag()                        // must not reset the live drag
        #expect(doc.meshEdit?.vertexDrag?.hasPreview == true)
    }

    @Test func additiveSelectionTogglesVertices() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 0)
        doc.selectMeshVertex(index: 1, additive: true)
        guard case .vertices(let sel)? = doc.meshEdit?.componentSelection else {
            Issue.record("expected vertex selection"); return
        }
        #expect(sel.count == 2)
        doc.selectMeshVertex(index: 1, additive: true) // toggle off
        guard case .vertices(let sel2)? = doc.meshEdit?.componentSelection else { return }
        #expect(sel2.count == 1)
    }

    @Test func commitFlushesDragAsOneUndoableCommand() {
        let (doc, path) = makeGridDocument()
        doc.selectMeshVertex(index: 0)
        doc.beginVertexDrag()
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        doc.endVertexDrag()
        doc.exitMeshEditMode(commit: true)

        guard case .float3Array(let pts)? =
            doc.snapshot.prim(at: path)?.attribute(named: "points")?.value else {
            Issue.record("points not flushed"); return
        }
        #expect(abs(pts[2] - 1) < 1e-6) // first vertex z lifted to 1
        #expect(doc.canUndo)
        doc.undo()
        guard case .float3Array(let restored)? =
            doc.snapshot.prim(at: path)?.attribute(named: "points")?.value else { return }
        #expect(abs(restored[2]) < 1e-6) // back to z=0
    }

    @Test func inSessionUndoRewindsOneWholeDrag() {
        let (doc, _) = makeGridDocument()
        doc.selectMeshVertex(index: 0)
        doc.beginVertexDrag()
        doc.updateVertexDrag(translation: SIMD3(0, 0, 1))
        doc.endVertexDrag()
        doc.undoMeshEdit()
        #expect(abs(position(doc, 0).z) < 1e-9)
        #expect(doc.meshEdit?.session.isDirty == false)
    }
}
