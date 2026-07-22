import Testing
import Foundation
import USDCore
import MeshKit
import ViewportKit
@testable import EditorUI

@MainActor
private func makeDocument(skinned: Bool = false) -> (EditorDocument, PrimPath) {
    let path = PrimPath("/Root/Panel")!
    var relationships: [Relationship] = []
    if skinned { relationships.append(Relationship(name: "skel:skeleton", targets: [])) }
    // Unit cube (8 verts, 6 quads).
    let mesh = Prim(
        path: path, typeName: "Mesh",
        attributes: [
            Attribute(name: "points", value: .float3Array([
                0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1])),
            Attribute(name: "faceVertexCounts", value: .intArray([4,4,4,4,4,4])),
            Attribute(name: "faceVertexIndices", value: .intArray([
                0,3,2,1, 4,5,6,7, 0,1,5,4, 1,2,6,5, 2,3,7,6, 3,0,4,7])),
        ],
        relationships: relationships)
    let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [mesh])
    return (EditorDocument(snapshot: StageSnapshot(rootPrims: [root])), path)
}

@MainActor
@Suite("Lattice mode")
struct LatticeModeTests {

    private func points(_ doc: EditorDocument, _ path: PrimPath) -> [Double]? {
        if case .float3Array(let p)? = doc.snapshot.prim(at: path)?.attribute(named: "points")?.value {
            return p
        }
        return nil
    }

    @Test func enterFitsCageToBounds() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        let availability = doc.enterLatticeMode(at: path)
        #expect(availability == .available)
        let state = try! #require(doc.latticeEdit)
        #expect(state.path == path)
        #expect(state.cage.resolution == .default)
        // 2×2×2 cage padded around the unit cube: origin below zero.
        #expect(state.cage.origin.x < 0)
        #expect(!state.isDeformed)
    }

    @Test func toggleDescendsAndTogglesOff() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([PrimPath("/Root")!])
        doc.toggleLatticeMode()
        #expect(doc.latticeEdit?.path == path)     // descended to the mesh
        #expect(doc.latticeRefusal == nil)
        doc.toggleLatticeMode()                    // toggle off (no deform → no command)
        #expect(doc.latticeEdit == nil)
        #expect(!doc.canUndo)
    }

    @Test func toggleWithNothingSelectedRefuses() {
        let (doc, _) = makeDocument()
        doc.toggleLatticeMode()
        #expect(doc.latticeEdit == nil)
        #expect(doc.latticeRefusal != nil)
    }

    @Test func toggleSkinnedRefuses() {
        let (doc, path) = makeDocument(skinned: true)
        doc.selection = Selection([path])
        doc.toggleLatticeMode()
        #expect(doc.latticeEdit == nil)
        #expect(doc.latticeRefusal != nil)
    }

    @Test func dragDeformsAndCommitBakesUndoably() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        let original = try! #require(points(doc, path))

        // Grab the max corner handle (index 7 of a 2×2×2 grid) and pull it +x.
        doc.handleLatticeCageDrag(.began(handle: 7))
        doc.handleLatticeCageDrag(.changed(handle: 7, worldDelta: SIMD3(2, 0, 0)))
        doc.handleLatticeCageDrag(.ended)
        #expect(doc.latticeEdit?.isDeformed == true)
        #expect(doc.latticeEdit?.dragStart == nil)   // cleared on end

        doc.exitLatticeMode(commit: true)
        #expect(doc.latticeEdit == nil)
        #expect(doc.canUndo)
        let baked = try! #require(points(doc, path))
        #expect(baked != original)

        doc.undo()
        #expect(points(doc, path) == original)
    }

    @Test func multiHandleDragMovesRigidly() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        var state = try! #require(doc.latticeEdit)
        state.selectedHandles = [0, 7]
        doc.latticeEdit = state
        doc.handleLatticeCageDrag(.began(handle: 0))   // keeps the existing multi-selection
        doc.handleLatticeCageDrag(.changed(handle: 0, worldDelta: SIMD3(0, 1, 0)))
        let cps = doc.latticeEdit!.cage.controlPoints
        let rest = doc.latticeEdit!.restCage.controlPoints
        #expect(cps[0].y == rest[0].y + 1)
        #expect(cps[7].y == rest[7].y + 1)
        #expect(cps[3] == rest[3])                     // unselected handle unmoved
    }

    @Test func dragWithNoSelectionUsesGrabbedHandle() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        doc.latticeEdit?.selectedHandles = []
        doc.handleLatticeCageDrag(.changed(handle: 2, worldDelta: SIMD3(0, 0, 1)))
        let cps = doc.latticeEdit!.cage.controlPoints
        #expect(cps[2].z == doc.latticeEdit!.restCage.controlPoints[2].z + 1)
    }

    @Test func exitWithoutCommitDiscards() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        let original = try! #require(points(doc, path))
        doc.handleLatticeCageDrag(.began(handle: 7))
        doc.handleLatticeCageDrag(.changed(handle: 7, worldDelta: SIMD3(2, 0, 0)))
        doc.exitLatticeMode(commit: false)
        #expect(doc.latticeEdit == nil)
        #expect(!doc.canUndo)
        #expect(points(doc, path) == original)
    }

    @Test func resolutionClampsAndResetsDeformation() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        doc.handleLatticeCageDrag(.began(handle: 7))
        doc.handleLatticeCageDrag(.changed(handle: 7, worldDelta: SIMD3(2, 0, 0)))
        #expect(doc.latticeEdit?.isDeformed == true)
        doc.setLatticeResolution(l: 99, m: 1, n: 3)     // clamps to 8 / 2 / 3
        let r = doc.latticeEdit!.cage.resolution
        #expect(r == LatticeCage.Resolution(l: 8, m: 2, n: 3))
        #expect(doc.latticeEdit?.isDeformed == false)   // topology change resets
    }

    @Test func interpolationAndAffectOutsideTogglePreserveControlPoints() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        doc.handleLatticeCageDrag(.began(handle: 7))
        doc.handleLatticeCageDrag(.changed(handle: 7, worldDelta: SIMD3(1, 0, 0)))
        let deformed = doc.latticeEdit!.cage.controlPoints
        doc.setLatticeInterpolation(.cubicBSpline)
        doc.setLatticeAffectOutside(true)
        #expect(doc.latticeEdit?.cage.interpolation == .cubicBSpline)
        #expect(doc.latticeEdit?.cage.affectOutside == true)
        #expect(doc.latticeEdit?.cage.controlPoints == deformed)   // control points preserved
    }

    @Test func resetRestoresRestCage() {
        let (doc, path) = makeDocument()
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        doc.handleLatticeCageDrag(.began(handle: 7))
        doc.handleLatticeCageDrag(.changed(handle: 7, worldDelta: SIMD3(2, 0, 0)))
        #expect(doc.latticeEdit?.isDeformed == true)
        doc.resetLattice()
        #expect(doc.latticeEdit?.isDeformed == false)
    }

    @Test func gizmoDescriptorReflectsState() {
        let (doc, path) = makeDocument()
        #expect(doc.latticeCageGizmo == nil)           // not in mode
        doc.selection = Selection([path])
        doc.enterLatticeMode(at: path)
        let g = try! #require(doc.latticeCageGizmo)
        #expect(g.controlPoints.count == 8)
        #expect(g.resolution == .default)
    }

    @Test func controlsAreNoOpsOutsideLatticeMode() {
        let (doc, _) = makeDocument()
        // No latticeEdit: every mutator guards and does nothing.
        doc.setLatticeResolution(l: 3, m: 3, n: 3)
        doc.setLatticeInterpolation(.cubicBSpline)
        doc.setLatticeAffectOutside(true)
        doc.resetLattice()
        doc.handleLatticeCageDrag(.began(handle: 0))
        doc.exitLatticeMode(commit: true)
        #expect(doc.latticeEdit == nil)
        #expect(!doc.canUndo)
    }

    @Test func fittedCageRejectsEmptyCloud() {
        #expect(EditorDocument.fittedCage(for: []) == nil)
    }
}
