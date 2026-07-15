import Testing
import USDCore
@testable import EditingKit

private func xform(_ path: String, translate t: [Double] = [0, 0, 0], children: [Prim] = []) -> Prim {
    let attr = Attribute(name: transformAttributeName,
                         value: .matrix4(TRS(translation: t).toMatrix()))
    return Prim(path: PrimPath(path)!, typeName: "Xform", attributes: [attr], children: children)
}

@Suite("DuplicatePrimCommand")
struct DuplicatePrimCommandTests {

    private func stage() -> InMemoryStage {
        let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh")
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheel])
        return InMemoryStage(StageSnapshot(rootPrims: [car]))
    }

    @Test func duplicatesAsUniqueSiblingAndUndoes() throws {
        let s = stage()
        let cmd = try #require(DuplicatePrimCommand.make(path: PrimPath("/Car/Wheel")!, in: s))
        #expect(cmd.duplicatePath == PrimPath("/Car/Wheel_1")!)

        try cmd.execute(on: s)
        #expect(s.prim(at: PrimPath("/Car/Wheel")!) != nil)
        #expect(s.prim(at: PrimPath("/Car/Wheel_1")!) != nil)
        // Inserted immediately after the original.
        #expect(s.currentSnapshot.prim(at: PrimPath("/Car")!)?.children.map(\.name) == ["Wheel", "Wheel_1"])

        try cmd.undo(on: s)
        #expect(s.prim(at: PrimPath("/Car/Wheel_1")!) == nil)
    }

    @Test func deepCopyRewritesDescendantPaths() throws {
        let hub = Prim(path: PrimPath("/Car/Wheel/Hub")!, typeName: "Mesh")
        let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Xform", children: [hub])
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheel])
        let s = InMemoryStage(StageSnapshot(rootPrims: [car]))

        let cmd = try #require(DuplicatePrimCommand.make(path: PrimPath("/Car/Wheel")!, in: s))
        try cmd.execute(on: s)
        #expect(s.prim(at: PrimPath("/Car/Wheel_1/Hub")!) != nil)
    }
}

@Suite("ReparentPrimCommand")
struct ReparentPrimCommandTests {

    /// Root-level child at world x=5; target parent at world x=10.
    private func stage() -> InMemoryStage {
        let child = xform("/Child", translate: [5, 0, 0])
        let target = xform("/Target", translate: [10, 0, 0])
        return InMemoryStage(StageSnapshot(rootPrims: [child, target]))
    }

    @Test func preservesWorldTransform() throws {
        let s = stage()
        let cmd = try #require(
            ReparentPrimCommand.make(path: PrimPath("/Child")!, under: PrimPath("/Target")!, in: s))
        try cmd.execute(on: s)

        let moved = PrimPath("/Target/Child")!
        #expect(s.prim(at: moved) != nil)
        #expect(s.prim(at: PrimPath("/Child")!) == nil)
        // New local x must compensate the parent's +10 so world stays at +5.
        #expect(abs(s.transform(at: moved).translation[0] - (-5)) < 1e-9)
        // World transform is unchanged.
        #expect(abs(s.worldMatrix(at: moved)[12] - 5) < 1e-9)
    }

    @Test func undoRestoresOriginalLocationAndTransform() throws {
        let s = stage()
        let cmd = try #require(
            ReparentPrimCommand.make(path: PrimPath("/Child")!, under: PrimPath("/Target")!, in: s))
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        #expect(s.prim(at: PrimPath("/Child")!) != nil)
        #expect(abs(s.transform(at: PrimPath("/Child")!).translation[0] - 5) < 1e-9)
    }

    @Test func rejectsCyclesNoOpsAndMissing() {
        let s = stage()
        // Into its own subtree (Target under Child, then Child under Target).
        let nest = ReparentPrimCommand.make(path: PrimPath("/Target")!, under: PrimPath("/Child")!, in: s)
        #expect(nest != nil)   // valid the first time
        // Reparent to current parent (root → root) is a no-op.
        #expect(ReparentPrimCommand.make(path: PrimPath("/Child")!, under: nil, in: s) == nil)
        // Missing prim.
        #expect(ReparentPrimCommand.make(path: PrimPath("/Nope")!, under: PrimPath("/Target")!, in: s) == nil)
    }

    @Test func rejectsReparentingUnderOwnDescendant() {
        let inner = xform("/A/Inner", translate: [0, 0, 0])
        let a = Prim(path: PrimPath("/A")!, typeName: "Xform", children: [inner])
        let s = InMemoryStage(StageSnapshot(rootPrims: [a]))
        #expect(ReparentPrimCommand.make(path: PrimPath("/A")!, under: PrimPath("/A/Inner")!, in: s) == nil)
    }
}

@Suite("GroupPrimsCommand")
struct GroupPrimsCommandTests {

    private func stage() -> InMemoryStage {
        let a = Prim(path: PrimPath("/Root/A")!, typeName: "Mesh")
        let b = Prim(path: PrimPath("/Root/B")!, typeName: "Mesh")
        let c = Prim(path: PrimPath("/Root/C")!, typeName: "Mesh")
        let root = Prim(path: PrimPath("/Root")!, typeName: "Xform", children: [a, b, c])
        return InMemoryStage(StageSnapshot(rootPrims: [root]))
    }

    @Test func nestsSelectedSiblingsUnderNewXform() throws {
        let s = stage()
        let cmd = try #require(GroupPrimsCommand.make(
            paths: [PrimPath("/Root/A")!, PrimPath("/Root/C")!], in: s))
        #expect(cmd.groupPath == PrimPath("/Root/Group")!)

        try cmd.execute(on: s)
        let rootChildren = s.currentSnapshot.prim(at: PrimPath("/Root")!)!.children.map(\.name)
        #expect(rootChildren.contains("Group"))
        #expect(!rootChildren.contains("A"))
        #expect(!rootChildren.contains("C"))
        #expect(rootChildren.contains("B"))
        #expect(s.prim(at: PrimPath("/Root/Group/A")!) != nil)
        #expect(s.prim(at: PrimPath("/Root/Group/C")!) != nil)
    }

    @Test func undoRestoresOriginalOrder() throws {
        let s = stage()
        let cmd = try #require(GroupPrimsCommand.make(
            paths: [PrimPath("/Root/A")!, PrimPath("/Root/C")!], in: s))
        try cmd.execute(on: s)
        try cmd.undo(on: s)
        let names = s.currentSnapshot.prim(at: PrimPath("/Root")!)!.children.map(\.name)
        #expect(names == ["A", "B", "C"])
    }

    @Test func rejectsCrossParentSelection() {
        let s = stage()
        #expect(GroupPrimsCommand.make(paths: [PrimPath("/Root/A")!, PrimPath("/Root")!], in: s) == nil)
    }
}
