import Testing
import Foundation
import EditingKit
@testable import SessionKit

/// Coverage for deriving a recovery plan from a write-ahead log: locating the
/// last checkpoint and returning only the records that follow it.
struct RecoveryPlanTests {

    private let url = URL(fileURLWithPath: "/tmp/model.usdz")

    @Test func emptyLogHasNoPlan() {
        #expect(RecoveryPlan.derive(from: []) == nil)
    }

    @Test func logWithoutCheckpointHasNoPlan() {
        let records: [JournalRecord] = [.undo, .redo]
        #expect(RecoveryPlan.derive(from: records) == nil)
    }

    @Test func planReplaysRecordsAfterCheckpoint() throws {
        let records: [JournalRecord] = [
            .checkpoint(sourceURL: url),
            .command(label: "Rename", forward: [], inverse: []),
            .undo,
        ]
        let plan = try #require(RecoveryPlan.derive(from: records))
        #expect(plan.sourceURL == url)
        #expect(plan.records.count == 2)
        #expect(plan.isEmpty == false)
    }

    @Test func planUsesLastCheckpointOnly() throws {
        let second = URL(fileURLWithPath: "/tmp/saved.usdz")
        let records: [JournalRecord] = [
            .checkpoint(sourceURL: url),
            .command(label: "A", forward: [], inverse: []),
            .checkpoint(sourceURL: second),               // a later save flattened history
            .command(label: "B", forward: [], inverse: []),
        ]
        let plan = try #require(RecoveryPlan.derive(from: records))
        #expect(plan.sourceURL == second)
        #expect(plan.records.count == 1)
    }

    @Test func checkpointOnlyLogIsEmptyPlan() throws {
        let plan = try #require(RecoveryPlan.derive(from: [.checkpoint(sourceURL: nil)]))
        #expect(plan.sourceURL == nil)
        #expect(plan.isEmpty)
    }

    @Test func recoveryPlanIsConstructible() {
        let plan = RecoveryPlan(sourceURL: url, records: [.undo])
        #expect(plan.sourceURL == url)
        #expect(plan.records == [.undo])
    }
}
