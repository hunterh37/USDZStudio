import Testing
import USDCore
import MeshKit
import EditingKit
import ViewportKit
import simd
@testable import EditorUI

/// `EditorDocument.viewportScene` projects the live stage into the viewport's
/// renderable description — the seam that lets prims which never existed in the
/// opened file (library inserts, scripts, MCP edits) render like any other.
@Suite("ViewportScene projection")
@MainActor
struct ViewportSceneProjectionTests {

    private func meshPrim(_ path: String, points: [Double] = [0, 0, 0, 1, 0, 0, 1, 1, 0],
                          counts: [Int] = [3], indices: [Int] = [0, 1, 2],
                          extraAttributes: [Attribute] = []) -> Prim {
        Prim(path: PrimPath(path)!, typeName: "Mesh",
             attributes: [
                Attribute(name: "points", value: .float3Array(points)),
                Attribute(name: "faceVertexCounts", value: .intArray(counts)),
                Attribute(name: "faceVertexIndices", value: .intArray(indices)),
             ] + extraAttributes)
    }

    private func cube() -> ShapeEntry { ShapeLibrary.entry(id: "prim.cube")! }

    // MARK: Geometry extraction

    @Test("A Mesh prim projects its points and face loops")
    func meshProjects() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [meshPrim("/M")]))
        let mesh = doc.viewportScene["/M"]?.mesh
        #expect(mesh?.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)])
        #expect(mesh?.faceLoops == [[0, 1, 2]])
    }

    @Test("Multi-face topology splits into one loop per face")
    func multipleFaces() {
        let prim = meshPrim("/M", points: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
                            counts: [3, 3], indices: [0, 1, 2, 0, 2, 3])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [prim]))
        #expect(doc.viewportScene["/M"]?.mesh?.faceLoops == [[0, 1, 2], [0, 2, 3]])
    }

    @Test("An n-gon face keeps all of its vertices")
    func ngonFace() {
        let prim = meshPrim("/M", points: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
                            counts: [4], indices: [0, 1, 2, 3])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [prim]))
        #expect(doc.viewportScene["/M"]?.mesh?.faceLoops == [[0, 1, 2, 3]])
    }

    @Test("A non-Mesh grouping prim projects with no geometry")
    func xformHasNoMesh() {
        let xform = Prim(path: PrimPath("/Group")!, typeName: "Xform")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [xform]))
        #expect(doc.viewportScene["/Group"] != nil)
        #expect(doc.viewportScene["/Group"]?.mesh == nil)
    }

    // MARK: Malformed geometry is rejected, not half-drawn

    @Test("A Mesh missing points projects no geometry")
    func missingPoints() {
        let prim = Prim(path: PrimPath("/M")!, typeName: "Mesh",
                        attributes: [Attribute(name: "faceVertexCounts", value: .intArray([3]))])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [prim]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    @Test("A Mesh missing its index array projects no geometry")
    func missingIndices() {
        let prim = Prim(path: PrimPath("/M")!, typeName: "Mesh",
                        attributes: [
                            Attribute(name: "points", value: .float3Array([0, 0, 0])),
                            Attribute(name: "faceVertexCounts", value: .intArray([3])),
                        ])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [prim]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    @Test("A Mesh missing its face-count array projects no geometry")
    func missingCounts() {
        let prim = Prim(path: PrimPath("/M")!, typeName: "Mesh",
                        attributes: [
                            Attribute(name: "points", value: .float3Array([0, 0, 0])),
                            Attribute(name: "faceVertexIndices", value: .intArray([0])),
                        ])
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [prim]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    @Test("A point array that isn't a multiple of three is rejected")
    func raggedPointArray() {
        let doc = EditorDocument(snapshot: StageSnapshot(
            rootPrims: [meshPrim("/M", points: [0, 0, 0, 1, 0])]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    @Test("A face count overrunning the index array is rejected")
    func faceCountOverrunsIndices() {
        let doc = EditorDocument(snapshot: StageSnapshot(
            rootPrims: [meshPrim("/M", counts: [4], indices: [0, 1, 2])]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    @Test("A degenerate face of fewer than three vertices is rejected")
    func degenerateFace() {
        let doc = EditorDocument(snapshot: StageSnapshot(
            rootPrims: [meshPrim("/M", counts: [2], indices: [0, 1])]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    @Test("An index pointing past the end of the point array is rejected")
    func outOfRangeIndex() {
        let doc = EditorDocument(snapshot: StageSnapshot(
            rootPrims: [meshPrim("/M", counts: [3], indices: [0, 1, 99])]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    @Test("A Mesh with no faces at all projects no geometry")
    func emptyTopology() {
        let doc = EditorDocument(snapshot: StageSnapshot(
            rootPrims: [meshPrim("/M", counts: [], indices: [])]))
        #expect(doc.viewportScene["/M"]?.mesh == nil)
    }

    // MARK: Hierarchy, transforms, enablement

    @Test("Nested prims project at their full paths")
    func nestedPaths() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        #expect(doc.viewportScene["/Cube"] != nil)
        #expect(doc.viewportScene["/Cube/Geo"]?.mesh != nil)
    }

    @Test("An authored transform lands on the node")
    func transformProjects() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        doc.setTransform(PrimPath("/Cube")!, to: TRS(translation: [2, 0, 0]))
        let m = doc.viewportScene["/Cube"]?.transform
        #expect(m?.columns.3.x == 2)
    }

    @Test("A prim with no authored transform is identity")
    func identityWhenUnauthored() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [meshPrim("/M")]))
        #expect(doc.viewportScene["/M"]?.transform == matrix_identity_float4x4)
    }

    @Test("Prims on the live set are enabled")
    func livePrimsEnabled() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [meshPrim("/M")]))
        #expect(doc.viewportScene["/M"]?.isEnabled == true)
    }

    // MARK: Visibility (inherited, per UsdGeomImageable)

    @Test("Hiding a prim drops it from the render set")
    func hiddenPrimIsDisabled() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [meshPrim("/M")]))
        doc.performPartEdit(.hide, on: PrimPath("/M")!)
        #expect(doc.viewportScene["/M"]?.isEnabled == false)
    }

    @Test("Un-hiding restores it")
    func unhideReenables() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [meshPrim("/M")]))
        doc.performPartEdit(.hide, on: PrimPath("/M")!)
        doc.undo()
        #expect(doc.viewportScene["/M"]?.isEnabled == true)
    }

    @Test("An invisible parent hides its whole subtree")
    func hiddenParentHidesChildren() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        doc.performPartEdit(.hide, on: PrimPath("/Cube")!)

        #expect(doc.viewportScene["/Cube"]?.isEnabled == false)
        // The child authors no opinion of its own — it inherits the parent's.
        #expect(doc.viewportScene["/Cube/Geo"]?.isEnabled == false)
    }

    @Test("A visible parent leaves an explicitly hidden child hidden")
    func hiddenChildStaysHiddenUnderVisibleParent() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        doc.performPartEdit(.hide, on: PrimPath("/Cube/Geo")!)

        #expect(doc.viewportScene["/Cube"]?.isEnabled == true)
        #expect(doc.viewportScene["/Cube/Geo"]?.isEnabled == false)
    }

    @Test("Isolate hides the prims outside the isolated lineage")
    func isolateDisablesOthers() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        LibraryInsertion.insert(cube(), into: doc)
        doc.selection = Selection([PrimPath("/Cube/Geo")!])
        doc.isolateSelection()

        #expect(doc.viewportScene["/Cube/Geo"]?.isEnabled == true)
        #expect(doc.viewportScene["/Cube_1/Geo"]?.isEnabled == false)
    }

    // MARK: Cache behaviour

    @Test("Repeated reads at one revision return the same value")
    func cachedWithinRevision() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [meshPrim("/M")]))
        #expect(doc.viewportScene == doc.viewportScene)
    }

    @Test("An edit invalidates the cache — the insert shows up")
    func cacheInvalidatesOnEdit() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        #expect(doc.viewportScene.isEmpty)
        LibraryInsertion.insert(cube(), into: doc)
        #expect(doc.viewportScene["/Cube"] != nil)
    }

    @Test("Undoing an insert drops the prim back out of the scene")
    func undoRemovesFromScene() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        doc.undo()
        #expect(doc.viewportScene["/Cube"] == nil)
    }

    // MARK: The bug this whole seam exists to fix

    @Test("A library insert produces a real insert op against the prior scene")
    func insertDiffsAsAnInsertion() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        let before = doc.viewportScene
        LibraryInsertion.insert(cube(), into: doc)
        let ops = SceneGraphDiff.operations(from: before, to: doc.viewportScene)

        let insertedPaths = ops.compactMap { op -> String? in
            guard case .insert(let n) = op else { return nil }
            return n.path
        }
        #expect(insertedPaths == ["/Cube", "/Cube/Geo"])
        // …and the geometry actually rides along, rather than an empty node.
        guard case .insert(let geo)? = ops.last else { Issue.record("no geo insert"); return }
        #expect(geo.mesh?.faceLoops.isEmpty == false)
    }
}

