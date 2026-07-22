import Testing
import Foundation
import USDCore
import MeshKit
@testable import EditorUI

@MainActor
private func makeDocument(skinned: Bool = false) -> (EditorDocument, PrimPath) {
    let path = PrimPath("/Root/Panel")!
    var relationships: [Relationship] = []
    if skinned { relationships.append(Relationship(name: "skel:skeleton", targets: [])) }
    let mesh = Prim(
        path: path, typeName: "Mesh",
        attributes: [
            Attribute(name: "points",
                      value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([4])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3])),
        ],
        relationships: relationships)
    let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
    let document = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
    return (document, path)
}

/// USDZ-shaped document: the Mesh is nested two Xform scopes below the root,
/// the way imported models arrive (user selects the root, not the Mesh).
@MainActor
private func makeNestedDocument() -> (EditorDocument, root: PrimPath, mesh: PrimPath) {
    let meshPath = PrimPath("/Model/Geom/Body")!
    let mesh = Prim(
        path: meshPath, typeName: "Mesh",
        attributes: [
            Attribute(name: "points",
                      value: .float3Array([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])),
            Attribute(name: "faceVertexCounts", value: .intArray([4])),
            Attribute(name: "faceVertexIndices", value: .intArray([0, 1, 2, 3])),
        ])
    let geom = Prim(path: PrimPath("/Model/Geom")!, typeName: "Xform", children: [mesh])
    let root = Prim(path: PrimPath("/Model")!, typeName: "Xform", children: [geom])
    let document = EditorDocument(snapshot: StageSnapshot(rootPrims: [root]))
    return (document, PrimPath("/Model")!, meshPath)
}

@MainActor
@Suite("Tab toggle (USDZ-shaped selection)")
struct MeshEditToggleTests {

    @Test func tabDescendsFromXformRootToNestedMesh() {
        let (doc, root, meshPath) = makeNestedDocument()
        doc.selection = Selection([root])
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit != nil)
        #expect(doc.meshEdit?.session.path == meshPath)
        #expect(doc.meshEditRefusal == nil)
    }

    @Test func tabWithNothingSelectedSurfacesRefusal() {
        let (doc, _, _) = makeNestedDocument()
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit == nil)
        #expect(doc.meshEditRefusal != nil)
    }

    @Test func tabOnMeshlessSubtreeSurfacesRefusal() {
        let empty = Prim(path: PrimPath("/Empty")!, typeName: "Xform")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [empty]))
        doc.selection = Selection([PrimPath("/Empty")!])
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit == nil)
        #expect(doc.meshEditRefusal == MeshEditAvailability.notAMesh.refusalMessage)
    }

    @Test func tabOnSkinnedMeshSurfacesSkinnedRefusal() {
        let (doc, path) = makeDocument(skinned: true)
        doc.selection = Selection([path])
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit == nil)
        #expect(doc.meshEditRefusal == MeshEditAvailability.skinned.refusalMessage)
    }

    @Test func successfulToggleClearsStaleRefusal() {
        let (doc, root, _) = makeNestedDocument()
        doc.toggleMeshEditMode() // nothing selected → refusal
        #expect(doc.meshEditRefusal != nil)
        doc.selection = Selection([root])
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit != nil)
        #expect(doc.meshEditRefusal == nil)
        doc.toggleMeshEditMode() // Tab again exits cleanly
        #expect(doc.meshEdit == nil)
        #expect(doc.meshEditRefusal == nil)
    }
}

@MainActor
@Suite("Mesh edit mode (EditorDocument)")
struct MeshEditModeTests {

    @Test func entersEditModeOnMeshPrim() {
        let (doc, path) = makeDocument()
        #expect(doc.meshEditAvailability(at: path) == .available)
        #expect(doc.enterMeshEditMode(at: path) == .available)
        #expect(doc.meshEdit != nil)
        #expect(doc.meshEdit?.session.mesh.faceCount == 1)
    }

    @Test func editModeDefaultsToFirstFaceSelected() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        let first = doc.meshEdit!.session.mesh.faceOrder[0]
        #expect(doc.meshEdit?.componentSelection == .faces([first]))
        #expect(doc.meshEdit?.selectedFaceIndex == 0)
        // Extrude works immediately with no manual selection step.
        doc.meshEdit?.tool = .extrude
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic == nil)
        #expect(doc.meshEdit?.session.mesh.faceCount == 5)
    }

    @Test func facePickerClampsAndSelectsAll() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.selectMeshFace(index: 99) // clamped to last face
        #expect(doc.meshEdit?.selectedFaceIndex == 0) // single-face mesh
        doc.selectMeshFace(index: -5)
        #expect(doc.meshEdit?.selectedFaceIndex == 0)
        doc.selectMeshFace(index: nil)
        #expect(doc.meshEdit?.selectedFaceIndex == nil)
        if case .faces(let all)? = doc.meshEdit?.componentSelection {
            #expect(all.count == 1)
        } else { Issue.record("expected face selection") }
    }

    @Test func refusesSkinnedMeshWithDiagnostic() {
        let (doc, path) = makeDocument(skinned: true)
        let availability = doc.enterMeshEditMode(at: path)
        #expect(availability == .skinned)
        #expect(availability.refusalMessage?.contains("skeletal binding") == true)
        #expect(doc.meshEdit == nil)
    }

    @Test func refusesNonMeshPrim() {
        let (doc, _) = makeDocument()
        #expect(doc.enterMeshEditMode(at: PrimPath("/Root")!) == .notAMesh)
    }

    @Test func tabToggleUsesSelection() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit != nil)
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit == nil)
    }

    @Test func applyToolMutatesSessionAndCommitFlushesToStage() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.meshEdit?.tool = .extrude
        doc.meshEdit?.extrudeDistance = 0.5
        doc.meshEdit?.componentSelection = .faces([FaceID(0)])
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic == nil)
        #expect(doc.meshEdit?.session.mesh.faceCount == 5) // cap + 4 sides
        #expect(doc.meshEdit?.session.isDirty == true)

        doc.exitMeshEditMode(commit: true)
        #expect(doc.meshEdit == nil)
        guard case .intArray(let counts)? =
            doc.snapshot.prim(at: path)?.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("counts not flushed"); return
        }
        #expect(counts == [4, 4, 4, 4, 4])
        #expect(doc.canUndo) // one undoable MeshEditCommand
        doc.undo()
        guard case .intArray(let restored)? =
            doc.snapshot.prim(at: path)?.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("counts missing after undo"); return
        }
        #expect(restored == [4])
    }

    @Test func refusalSurfacesDiagnosticNotSilence() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.meshEdit?.tool = .extrude
        doc.meshEdit?.componentSelection = .faces([]) // empty → loud refusal
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic != nil)
        #expect(doc.meshEdit?.session.isDirty == false)
    }

    @Test func inSessionUndoRestoresWorkingMesh() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        let hash = doc.meshEdit!.session.mesh.topologyHash
        doc.meshEdit?.tool = .inset
        doc.meshEdit?.componentSelection = .faces([FaceID(0)])
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.session.canUndo == true)
        doc.undoMeshEdit()
        #expect(doc.meshEdit?.session.mesh.topologyHash == hash)
    }

    @Test func exitWithoutCommitDiscards() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.meshEdit?.tool = .delete
        doc.meshEdit?.componentSelection = .faces([FaceID(0)])
        doc.applyActiveMeshTool()
        doc.exitMeshEditMode(commit: false)
        #expect(!doc.canUndo)
        guard case .intArray(let counts)? =
            doc.snapshot.prim(at: path)?.attribute(named: "faceVertexCounts")?.value else {
            Issue.record("counts missing"); return
        }
        #expect(counts == [4]) // stage untouched
    }
}

@MainActor
@Suite("Bevel tool (EditorDocument)")
struct BevelToolTests {

    /// Extruding the quad gives a cap whose edges satisfy bevel's strict
    /// preconditions (interior edge, valence-3 endpoints).
    @MainActor
    private func extrudedDoc() -> (EditorDocument, capEdge: EdgeKey) {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.meshEdit?.tool = .extrude
        doc.meshEdit?.extrudeDistance = 0.5
        doc.meshEdit?.componentSelection = .faces([FaceID(0)])
        doc.applyActiveMeshTool()
        let cap = doc.meshEdit!.session.mesh.faceLoops[FaceID(0)]!
        return (doc, EdgeKey(cap[0], cap[1]))
    }

    @Test func bevelAppliesToEdgeSelection() {
        let (doc, capEdge) = extrudedDoc()
        doc.meshEdit?.tool = .bevel
        doc.meshEdit?.bevelWidth = 0.1
        doc.meshEdit?.componentSelection = .edges([capEdge])
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic == nil)
        #expect(doc.meshEdit?.session.mesh.faceCount == 6) // + bevel quad
        // Result selection is the new quad (faces), so it highlights in viewport.
        if case .faces(let f)? = doc.meshEdit?.componentSelection {
            #expect(f.count == 1)
        } else { Issue.record("expected face selection after bevel") }
    }

    @Test func edgePickerSelectsAndClamps() {
        let (doc, _) = extrudedDoc()
        doc.meshEdit?.tool = .bevel
        let edges = doc.meshEditEdges
        #expect(!edges.isEmpty)
        doc.selectMeshEdge(index: 999)
        #expect(doc.meshEdit?.selectedEdgeIndex == edges.count - 1)
        if case .edges(let picked)? = doc.meshEdit?.componentSelection {
            #expect(picked == [edges.last!])
        } else { Issue.record("edge picker did not set edge selection") }
    }

    @Test func bevelRefusalIsLoud() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path) // flat quad: every edge is boundary
        doc.meshEdit?.tool = .bevel
        let edge = doc.meshEditEdges.first!
        doc.meshEdit?.componentSelection = .edges([edge])
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic != nil)
        #expect(doc.meshEdit?.session.isDirty == false)
    }

    // #69: Mirror + Solidify are whole-mesh ops surfaced in edit mode.
    @Test func mirrorAppliesWholeMesh() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.meshEdit?.tool = .mirror
        doc.meshEdit?.mirrorAxis = .x
        doc.meshEdit?.mirrorCoordinate = 2   // plane clear of the quad (x∈[0,1])
        // Selection is a single face, but the op acts on the whole mesh.
        doc.meshEdit?.componentSelection = .faces([FaceID(0)])
        let before = doc.meshEdit!.session.mesh.faceCount
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic == nil)
        #expect(doc.meshEdit!.session.mesh.faceCount == before * 2)  // mirrored copy
    }

    @Test func mirrorRefusalIsLoud() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.meshEdit?.tool = .mirror
        doc.meshEdit?.mirrorCoordinate = 0.5   // plane cuts through the mesh
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic != nil)
        #expect(doc.meshEdit?.session.isDirty == false)
    }

    @Test func solidifyAppliesWholeMesh() {
        let (doc, path) = makeDocument()
        doc.enterMeshEditMode(at: path)
        doc.meshEdit?.tool = .solidify
        doc.meshEdit?.solidifyThickness = 0.1
        let before = doc.meshEdit!.session.mesh.faceCount
        doc.applyActiveMeshTool()
        #expect(doc.meshEdit?.lastDiagnostic == nil)
        #expect(doc.meshEdit!.session.mesh.faceCount > before)  // inner shell + walls
    }

    @Test func meshToolMetadataIsComplete() {
        for tool in MeshTool.allCases {
            #expect(!tool.label.isEmpty)
            #expect(!tool.systemImage.isEmpty)
        }
        #expect(MeshTool.mirror.hotkey == "r")
        #expect(MeshTool.solidify.hotkey == "s")
        #expect(MeshTool.mirror.isWholeMesh)
        #expect(MeshTool.solidify.isWholeMesh)
        #expect(!MeshTool.extrude.isWholeMesh)
    }
}
