import Testing
import USDCore
@testable import EditingKit

@Suite("ReplaceStageCommand")
struct ReplaceStageCommandTests {

    private func prim(_ path: String, _ type: String = "Xform") -> Prim {
        Prim(path: PrimPath(path)!, typeName: type)
    }

    private var before: StageSnapshot {
        StageSnapshot(metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0),
                      rootPrims: [prim("/Alpha"), prim("/Beta")])
    }

    private var after: StageSnapshot {
        StageSnapshot(metadata: StageMetadata(upAxis: .z, metersPerUnit: 0.01, defaultPrim: "Gamma"),
                      rootPrims: [prim("/Gamma", "Mesh"), prim("/Delta"), prim("/Epsilon")])
    }

    @Test func executeReplacesMetadataAndRoots() throws {
        let stage = InMemoryStage(before)
        try ReplaceStageCommand(before: before, after: after, opLabel: "Console").execute(on: stage)

        #expect(stage.metadata.upAxis == .z)
        #expect(stage.metadata.metersPerUnit == 0.01)
        #expect(stage.metadata.defaultPrim == "Gamma")
        #expect(stage.currentSnapshot.rootPrims.map(\.path.name) == ["Gamma", "Delta", "Epsilon"])
        #expect(stage.prim(at: PrimPath("/Gamma")!)?.typeName == "Mesh")
        #expect(stage.prim(at: PrimPath("/Alpha")!) == nil)
    }

    @Test func undoRestoresOriginal() throws {
        let stage = InMemoryStage(before)
        let command = ReplaceStageCommand(before: before, after: after, opLabel: "Console")
        try command.execute(on: stage)
        try command.undo(on: stage)

        #expect(stage.metadata.upAxis == .y)
        #expect(stage.metadata.defaultPrim == nil)
        #expect(stage.currentSnapshot.rootPrims.map(\.path.name) == ["Alpha", "Beta"])
    }

    @Test func roundTripsThroughCommandStackWithRedo() throws {
        let stage = InMemoryStage(before)
        let stack = CommandStack(stage: stage)
        try stack.run(ReplaceStageCommand(before: before, after: after, opLabel: "Console: edit"))
        #expect(stack.undoLabel == "Console: edit")
        #expect(stage.currentSnapshot.rootPrims.count == 3)

        try stack.undo()
        #expect(stage.currentSnapshot.rootPrims.map(\.path.name) == ["Alpha", "Beta"])

        try stack.redo()
        #expect(stage.currentSnapshot.rootPrims.map(\.path.name) == ["Gamma", "Delta", "Epsilon"])
    }

    @Test func handlesSharedRootNamesWithoutCollision() throws {
        // Both forests contain a "/Shared" root — removing all before-roots first
        // must let the after-roots insert cleanly.
        let a = StageSnapshot(rootPrims: [prim("/Shared"), prim("/Old")])
        let b = StageSnapshot(rootPrims: [prim("/Shared", "Mesh"), prim("/New")])
        let stage = InMemoryStage(a)
        let command = ReplaceStageCommand(before: a, after: b, opLabel: "Console")
        try command.execute(on: stage)
        #expect(stage.currentSnapshot.rootPrims.map(\.path.name) == ["Shared", "New"])
        #expect(stage.prim(at: PrimPath("/Shared")!)?.typeName == "Mesh")
    }

    @Test func labelIsOpLabel() {
        let command = ReplaceStageCommand(before: before, after: after, opLabel: "Console: foo")
        #expect(command.label == "Console: foo")
    }
}
