import Testing
import Foundation
import USDCore
@testable import EditingKit

/// Records applied mutations; no real stage needed to verify command logic.
final class RecordingStage: USDStageMutable, @unchecked Sendable {
    var sourceURL: URL? { nil }
    var metadata = StageMetadata()
    var rootPrims: [Prim] = []
    private(set) var applied: [StageMutation] = []

    func apply(_ mutation: StageMutation) throws {
        applied.append(mutation)
    }
}

@Suite("SetVisibilityCommand")
struct SetVisibilityCommandTests {

    let path = PrimPath("/Car/Wheel")!

    @Test func executeAppliesNewVisibility() throws {
        let stage = RecordingStage()
        let command = SetVisibilityCommand(path: path, newVisibility: .invisible, oldVisibility: .inherited)
        try command.execute(on: stage)
        #expect(stage.applied == [.setVisibility(path: path, visibility: .invisible)])
    }

    @Test func undoRestoresOldVisibility() throws {
        let stage = RecordingStage()
        let command = SetVisibilityCommand(path: path, newVisibility: .invisible, oldVisibility: .inherited)
        try command.execute(on: stage)
        try command.undo(on: stage)
        #expect(stage.applied.last == .setVisibility(path: path, visibility: .inherited))
    }

    @Test func labelsNameThePart() {
        #expect(SetVisibilityCommand(path: path, newVisibility: .invisible, oldVisibility: .inherited).label == "Hide Wheel")
        #expect(SetVisibilityCommand(path: path, newVisibility: .inherited, oldVisibility: .invisible).label == "Show Wheel")
    }
}
