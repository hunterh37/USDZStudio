import Testing
import Foundation
import USDCore
@testable import EditingKit

/// Fills the small, scattered coverage gaps across EditingKit so the module
/// meets its 100% floor (specs/testing.md): attribute commands, stack history
/// management, transform helper deltas, structure-command labels, in-memory
/// error paths, gimbal-lock decomposition, and material resolution conveniences.
/// Thread-safe counter — `CommandStack.onChange` is a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("EditingKit coverage closure")
struct EditingKitCoverageClosureTests {

    private func stage(_ roots: [Prim]) -> InMemoryStage {
        InMemoryStage(StageSnapshot(rootPrims: roots))
    }
    private let path = PrimPath("/A")!

    // MARK: Set/RemoveAttributeCommand

    @Test func setAttributeLabelAndUndoToPriorValue() throws {
        let old = Attribute(name: "size", value: .double(1))
        let new = Attribute(name: "size", value: .double(2))
        let cmd = SetAttributeCommand(path: path, newAttribute: new, oldAttribute: old)
        #expect(cmd.label == "Set size")
        let s = stage([Prim(path: path, attributes: [old])])
        try cmd.execute(on: s)
        #expect(s.prim(at: path)?.attribute(named: "size")?.value == .double(2))
        try cmd.undo(on: s)
        #expect(s.prim(at: path)?.attribute(named: "size")?.value == .double(1))
    }

    @Test func removeAttributeCommandRoundTripAndLabel() throws {
        let attr = Attribute(name: "color", value: .vector([1, 0, 0]))
        let s = stage([Prim(path: path, attributes: [attr])])
        let cmd = try #require(RemoveAttributeCommand.make(path: path, name: "color", in: s))
        #expect(cmd.label == "Clear color")
        try cmd.execute(on: s)
        #expect(s.prim(at: path)?.attribute(named: "color") == nil)
        try cmd.undo(on: s)
        #expect(s.prim(at: path)?.attribute(named: "color")?.value == .vector([1, 0, 0]))
    }

    @Test func removeAttributeMakeReturnsNilWhenAbsent() {
        let s = stage([Prim(path: path)])
        #expect(RemoveAttributeCommand.make(path: path, name: "nope", in: s) == nil)
    }

    // MARK: CommandStack.clear + redoLabel

    @Test func clearEmptiesHistoryAndFiresOnChange() throws {
        let s = stage([Prim(path: path, attributes: [Attribute(name: "v", value: .double(0))])])
        let stack = CommandStack(stage: s)
        let changes = Counter()
        stack.onChange = { changes.bump() }
        try stack.run(SetAttributeCommand(
            path: path, newAttribute: Attribute(name: "v", value: .double(1)),
            oldAttribute: Attribute(name: "v", value: .double(0))))
        try stack.undo()
        #expect(stack.redoLabel == "Set v")
        stack.clear()
        #expect(!stack.canUndo && !stack.canRedo)
        #expect(stack.redoLabel == nil)
        #expect(changes.value == 3)  // run + undo + clear
    }

    // MARK: TransformCommand relative deltas

    @Test func rotateAndScaleDeltasComposeOnStart() throws {
        let start = TRS(translation: [0, 0, 0], rotationEulerDegrees: [10, 0, 0], scale: [2, 2, 2])
        let prim = Prim(path: path, attributes: [
            Attribute(name: "xformOp:transform", value: .matrix4(start.toMatrix()))])
        let s = stage([prim])
        let session = TransformDragSession(stage: s, path: path)
        let rotated = try session.rotate(byDegrees: [5, 0, 0])
        #expect(abs(rotated.rotationEulerDegrees[0] - 15) < 1e-6)
        let scaled = try session.scale(by: 3)
        #expect(scaled.scale.allSatisfy { abs($0 - 6) < 1e-6 })
    }

    // MARK: structure-command labels + append-transform branch

    @Test func structureCommandLabels() throws {
        let child = Prim(path: PrimPath("/P/C")!, typeName: "Mesh")
        let p = Prim(path: PrimPath("/P")!, typeName: "Xform", children: [child])
        let q = Prim(path: PrimPath("/Q")!, typeName: "Xform")
        let s = stage([p, q])

        let dup = try #require(DuplicatePrimCommand.make(path: PrimPath("/P/C")!, in: s))
        #expect(dup.label == "Duplicate C_1")  // uniqued against sibling C

        let reparent = try #require(
            ReparentPrimCommand.make(path: PrimPath("/P/C")!, under: PrimPath("/Q")!, in: s))
        #expect(reparent.label == "Reparent C")
        // /C carried no xformOp:transform, so reparent authored one (append branch).
        try reparent.execute(on: s)
        #expect(s.prim(at: PrimPath("/Q/C")!)?.attribute(named: "xformOp:transform") != nil)

        let group = try #require(
            GroupPrimsCommand.make(paths: [PrimPath("/P")!, PrimPath("/Q")!], in: s))
        #expect(group.label == "Group 2 Prims")
    }

    // MARK: InMemoryStage error paths + sourceURL passthrough

    @Test func sourceURLPassesThrough() {
        let url = URL(fileURLWithPath: "/tmp/x.usda")
        let s = InMemoryStage(StageSnapshot(sourceURL: url, rootPrims: []))
        #expect(s.sourceURL == url)
    }

    @Test func renamesNestedPrimSuccessfully() throws {
        let child = Prim(path: PrimPath("/P/C")!, typeName: "Mesh")
        let s = stage([Prim(path: PrimPath("/P")!, typeName: "Xform", children: [child])])
        try s.apply(.renamePrim(path: PrimPath("/P/C")!, newName: "D"))
        #expect(s.prim(at: PrimPath("/P/D")!) != nil)
        #expect(s.prim(at: PrimPath("/P/C")!) == nil)
    }

    @Test func renameToInvalidNameThrows() {
        let s = stage([Prim(path: path)])
        #expect(throws: StageMutationError.self) {
            try s.apply(.renamePrim(path: path, newName: "has space"))
        }
    }

    @Test func mutatingMissingPrimThrowsPrimNotFound() {
        let s = stage([Prim(path: path)])
        #expect(throws: StageMutationError.self) {
            try s.apply(.setActive(path: PrimPath("/Ghost")!, isActive: false))
        }
    }

    @Test func removingMissingPrimThrowsPrimNotFound() {
        let s = stage([Prim(path: path)])
        #expect(throws: StageMutationError.self) {
            try s.apply(.removePrim(path: PrimPath("/Ghost")!))
        }
    }

    @Test func insertsUnderExistingNonRootParent() throws {
        let s = stage([Prim(path: PrimPath("/P")!, typeName: "Xform")])
        try s.apply(.insertPrim(parent: PrimPath("/P")!, index: 0,
                                prim: Prim(path: PrimPath("/P/Child")!, typeName: "Mesh")))
        #expect(s.prim(at: PrimPath("/P/Child")!) != nil)
    }

    @Test func insertUnderMissingParentThrowsParentNotFound() {
        let s = stage([Prim(path: path)])
        #expect(throws: StageMutationError.self) {
            try s.apply(.insertPrim(parent: PrimPath("/Ghost")!, index: 0,
                                    prim: Prim(path: PrimPath("/Ghost/K")!)))
        }
    }

    // MARK: gimbal-lock decomposition branch

    @Test func decomposeHandlesGimbalLock() {
        let m = TRS(rotationEulerDegrees: [0, 90, 0]).toMatrix()
        let trs = TRS.from(matrix: m)
        #expect(abs(abs(trs.rotationEulerDegrees[1]) - 90) < 1e-6)
        #expect(trs.rotationEulerDegrees[2] == 0)  // rz folded into rx
    }

    // MARK: MaterialEditing conveniences

    @Test func previewSurfaceInputIdIsName() {
        let input = try! #require(PreviewSurfaceInput.catalog.first)
        #expect(input.id == input.name)
    }

    @Test func materialConvenienceReturnsBoundPrim() {
        let mat = Prim(path: PrimPath("/Looks/M")!, typeName: "Material")
        let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [mat])
        let obj = Prim(path: PrimPath("/Obj")!, typeName: "Mesh",
                       relationships: [Relationship(name: MaterialBinding.key,
                                                    targets: [PrimPath("/Looks/M")!])])
        let s = stage([looks, obj])
        #expect(MaterialBinding.material(for: PrimPath("/Obj")!, in: s)?.path == mat.path)
    }

    @Test func directBindingResolvesAbsolutePathInMetadata() {
        let mat = Prim(path: PrimPath("/Looks/M")!, typeName: "Material")
        let looks = Prim(path: PrimPath("/Looks")!, typeName: "Scope", children: [mat])
        let obj = Prim(path: PrimPath("/Obj")!, typeName: "Mesh",
                       metadata: [MaterialBinding.key: "/Looks/M"])
        let s = stage([looks, obj])
        #expect(MaterialBinding.materialPath(for: PrimPath("/Obj")!, in: s) == mat.path)
    }
}
