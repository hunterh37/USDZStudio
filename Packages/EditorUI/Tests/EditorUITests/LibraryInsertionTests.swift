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

    @Test func uniqueRootNameSanitizesAndSuffixes() {
        let existing = Prim(path: PrimPath("/Box")!, typeName: "Xform")
        let doc = EditorDocument(snapshot: StageSnapshot(rootPrims: [existing]))
        // Free name passes through; colliding name gets a numeric suffix.
        #expect(LibraryInsertion.uniqueRootName(base: "Tree", in: doc) == "Tree")
        #expect(LibraryInsertion.uniqueRootName(base: "Box", in: doc) == "Box_1")
    }
}
