import Testing
import USDCore
@testable import EditingKit

@Suite("SetStageMetadataCommand")
struct SetStageMetadataCommandTests {

    private func stage() -> InMemoryStage {
        InMemoryStage(StageSnapshot(metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0)))
    }

    @Test func executeAuthorsNewMetadataAndUndoRestores() throws {
        let s = stage()
        let old = s.metadata
        let new = StageMetadata(upAxis: .z, metersPerUnit: 0.01, defaultPrim: "Root")
        let command = SetStageMetadataCommand(newMetadata: new, oldMetadata: old)

        try command.execute(on: s)
        #expect(s.metadata.upAxis == .z)
        #expect(s.metadata.metersPerUnit == 0.01)
        #expect(s.metadata.defaultPrim == "Root")

        try command.undo(on: s)
        #expect(s.metadata == old)
    }

    @Test func roundTripsThroughCommandStack() throws {
        let s = stage()
        let stack = CommandStack(stage: s)
        let new = StageMetadata(upAxis: .z, metersPerUnit: 0.1)
        try stack.run(SetStageMetadataCommand(newMetadata: new, oldMetadata: s.metadata))
        #expect(s.metadata.upAxis == .z)
        try stack.undo()
        #expect(s.metadata.upAxis == .y)
        try stack.redo()
        #expect(s.metadata.metersPerUnit == 0.1)
    }

    @Test func labelIsStable() {
        let command = SetStageMetadataCommand(newMetadata: StageMetadata(), oldMetadata: StageMetadata())
        #expect(command.label == "Edit Stage Metadata")
    }
}
