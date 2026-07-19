import Testing
import USDCore
@testable import EditingKit

/// `InsertPrimCommand` is the inverse of `RemovePrimCommand` and the primitive
/// behind "add primitive" flows (e.g. the guided tour's cube). These exercise
/// it directly — root and nested insertion, sibling ordering, subtree round
/// trips, and exact undo — rather than only through higher-level callers.
@Suite("InsertPrimCommand")
struct InsertPrimCommandTests {

    private func stage() -> InMemoryStage {
        let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh")
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheel])
        return InMemoryStage(StageSnapshot(rootPrims: [car]))
    }

    @Test func insertsRootPrimAndUndoes() throws {
        let s = stage()
        let light = Prim(path: PrimPath("/Light")!, typeName: "SphereLight")
        let cmd = InsertPrimCommand(prim: light, parent: nil, index: 1)

        try cmd.execute(on: s)
        #expect(s.currentSnapshot.rootPrims.map(\.name) == ["Car", "Light"])
        #expect(s.prim(at: PrimPath("/Light")!)?.typeName == "SphereLight")

        try cmd.undo(on: s)
        #expect(s.currentSnapshot.rootPrims.map(\.name) == ["Car"])
        #expect(s.prim(at: PrimPath("/Light")!) == nil)
    }

    @Test func insertsRootPrimAtLeadingIndex() throws {
        let s = stage()
        let cmd = InsertPrimCommand(
            prim: Prim(path: PrimPath("/First")!, typeName: "Xform"),
            parent: nil, index: 0)
        try cmd.execute(on: s)
        #expect(s.currentSnapshot.rootPrims.map(\.name) == ["First", "Car"])
    }

    @Test func insertsNestedPrimAtIndexAndUndoes() throws {
        let s = stage()
        let cube = Prim(path: PrimPath("/Car/Cube")!, typeName: "Mesh")
        let cmd = InsertPrimCommand(prim: cube, parent: PrimPath("/Car")!, index: 0)

        try cmd.execute(on: s)
        // Inserted before the existing Wheel child.
        #expect(s.prim(at: PrimPath("/Car")!)?.children.map(\.name) == ["Cube", "Wheel"])

        try cmd.undo(on: s)
        #expect(s.prim(at: PrimPath("/Car")!)?.children.map(\.name) == ["Wheel"])
        #expect(s.prim(at: PrimPath("/Car/Cube")!) == nil)
    }

    @Test func insertsSubtreeAndUndoRemovesItWhole() throws {
        let s = stage()
        let hub = Prim(path: PrimPath("/Rig/Arm/Hub")!, typeName: "Mesh")
        let arm = Prim(path: PrimPath("/Rig/Arm")!, typeName: "Xform", children: [hub])
        let rig = Prim(path: PrimPath("/Rig")!, typeName: "Xform", children: [arm])
        let cmd = InsertPrimCommand(prim: rig, parent: nil, index: 0)

        try cmd.execute(on: s)
        #expect(s.prim(at: PrimPath("/Rig/Arm/Hub")!)?.typeName == "Mesh")

        try cmd.undo(on: s)
        #expect(s.prim(at: PrimPath("/Rig")!) == nil)
        #expect(s.prim(at: PrimPath("/Rig/Arm/Hub")!) == nil)
    }

    @Test func labelNamesTheInsertedPrim() {
        let cmd = InsertPrimCommand(
            prim: Prim(path: PrimPath("/Car/Cube")!, typeName: "Mesh"),
            parent: PrimPath("/Car")!, index: 0)
        #expect(cmd.label == "Add Cube")
    }

    @Test func executeThenUndoLeavesStageIdentical() throws {
        let s = stage()
        let before = s.currentSnapshot
        let cmd = InsertPrimCommand(
            prim: Prim(path: PrimPath("/Car/Extra")!, typeName: "Mesh"),
            parent: PrimPath("/Car")!, index: 1)
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        #expect(s.currentSnapshot == before)
    }
}
