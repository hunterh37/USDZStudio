import Testing
import USDCore
import EditingKit
import MeshKit
@testable import EditorUI

/// `LibraryInsertion` turns a `ShapeLibrary` entry into an undoable Xform+Mesh
/// prim in the open document, uniquifying the root name against existing prims.
@Suite("LibraryInsertion")
@MainActor
struct LibraryInsertionTests {

    private func cube() -> ShapeEntry { ShapeLibrary.entry(id: "prim.cube")! }

    @Test func insertAddsUndoableXformMeshPrim() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)

        #expect(doc.snapshot.rootPrims.count == 1)
        let root = doc.snapshot.rootPrims[0]
        #expect(root.name == "Cube")
        #expect(root.typeName == "Xform")

        let geo = root.children.first
        #expect(geo?.name == "Geo")
        #expect(geo?.typeName == "Mesh")
        // Low-poly stock must opt out of Catmull-Clark or it renders as a blob.
        #expect(geo?.attribute(named: "subdivisionScheme")?.value == .token("none"))
        #expect(geo?.attribute(named: "points") != nil)

        #expect(doc.canUndo)
        doc.undo()
        #expect(doc.snapshot.rootPrims.isEmpty)
    }

    @Test func insertSelectsTheNewPrim() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        // The inserted Xform must be selected so it behaves like any other
        // freshly created prim.
        #expect(doc.selection.paths == [PrimPath("/Cube")!])
    }

    @Test func insertedPrimCanEnterMeshEditModeViaToggle() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        // ⇥ right after a library insert must enter edit mode, not hit the
        // "Nothing selected" guard. `toggleMeshEditMode` descends the Xform to
        // its editable Mesh child.
        doc.toggleMeshEditMode()
        #expect(doc.meshEdit != nil)
        #expect(doc.meshEditRefusal == nil)
    }

    @Test func insertUniquifiesCollidingNames() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        LibraryInsertion.insert(cube(), into: doc)
        LibraryInsertion.insert(cube(), into: doc)
        LibraryInsertion.insert(cube(), into: doc)

        let names = doc.snapshot.rootPrims.map(\.name)
        #expect(names == ["Cube", "Cube_1", "Cube_2"])
    }

    @Test func makePrimReturnsXformWrappingGeo() throws {
        let mesh = try cube().build()
        let prim = LibraryInsertion.makePrim(named: "Widget", from: mesh)
        #expect(prim?.path == PrimPath("/Widget"))
        #expect(prim?.children.first?.path == PrimPath("/Widget/Geo"))
    }

    @Test func performInsertDismissesOnSuccess() {
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: []))
        var dismissed = false
        // A successful add closes the sheet so keyboard focus returns to the
        // editor — otherwise the library sheet swallows the ⇥ the user presses
        // next to enter edit mode on the object they just added.
        let status = LibraryPanel.performInsert(
            cube(), document: doc, createDocument: { nil }, dismiss: { dismissed = true })
        #expect(dismissed)
        #expect(status == "Added Cube to the scene.")
        #expect(doc.snapshot.rootPrims.count == 1)
    }

    @Test func performInsertCreatesScratchSceneWhenNoDocumentOpen() {
        // No file open: the library starts a fresh scratch document rather than
        // silently no-opping. The created scene ends up with the inserted prim
        // selected, so ⇥ can enter edit mode on it right away.
        var created: EditorDocument?
        var dismissed = false
        let status = LibraryPanel.performInsert(
            cube(), document: nil,
            createDocument: { let d = EditorDocument(snapshot: StageSnapshot(rootPrims: [])); created = d; return d },
            dismiss: { dismissed = true })
        #expect(dismissed)
        #expect(status == "Added Cube to the scene.")
        #expect(created?.snapshot.rootPrims.count == 1)
        #expect(created?.selection.paths == [PrimPath("/Cube")!])
    }

    @Test func performInsertReportsAndStaysOpenWhenNoSceneCanBeCreated() {
        // Can't create a scene (e.g. previews): report the failure and keep the
        // sheet open rather than dismissing into nothing.
        var dismissed = false
        let status = LibraryPanel.performInsert(
            cube(), document: nil, createDocument: { nil }, dismiss: { dismissed = true })
        #expect(!dismissed)
        #expect(status.contains("Couldn’t create a scene"))
    }

    @Test func uniqueRootNameSanitizesAndSuffixes() {
        let existing = Prim(path: PrimPath("/Box")!, typeName: "Xform")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [existing]))
        // Free name passes through; colliding name gets a numeric suffix.
        #expect(LibraryInsertion.uniqueRootName(base: "Tree", in: doc) == "Tree")
        #expect(LibraryInsertion.uniqueRootName(base: "Box", in: doc) == "Box_1")
    }
}
