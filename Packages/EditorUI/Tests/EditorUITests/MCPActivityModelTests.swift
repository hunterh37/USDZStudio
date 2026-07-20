import Testing
@testable import EditorUI

@MainActor
@Suite struct MCPActivityModelTests {

    @Test func startsDisconnectedAndEmpty() {
        let model = MCPActivityModel()
        #expect(model.isConnected == false)
        #expect(model.rows.isEmpty)
        #expect(model.runningCount == 0)
    }

    @Test func rowIdentityCombinesPidAndSeq() {
        let a = MCPCallRow(pid: 10, seq: 1, tool: "x", status: .running)
        let b = MCPCallRow(pid: 11, seq: 1, tool: "x", status: .running)
        #expect(a.id == "10-1")
        #expect(a.id != b.id)
    }

    @Test func runningCountCountsOnlyRunning() {
        let model = MCPActivityModel()
        model.rows = [
            MCPCallRow(pid: 1, seq: 1, tool: "a", status: .running),
            MCPCallRow(pid: 1, seq: 2, tool: "b", status: .success, durationMs: 3),
            MCPCallRow(pid: 1, seq: 3, tool: "c", status: .error, summary: "boom"),
            MCPCallRow(pid: 1, seq: 4, tool: "d", status: .running),
        ]
        #expect(model.runningCount == 2)
    }

    @Test func statusesAreDistinct() {
        #expect(MCPCallStatus.running != MCPCallStatus.success)
        #expect(MCPCallStatus.success != MCPCallStatus.error)
    }
}
