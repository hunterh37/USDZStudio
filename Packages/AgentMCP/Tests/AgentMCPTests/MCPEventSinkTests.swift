import Foundation
import Testing
import USDCore
@testable import AgentMCP

/// Records every callback so tests can assert the exact fire sequence.
final class SpyEventSink: MCPEventSink, @unchecked Sendable {
    struct Started: Equatable { var seq: Int; var tool: String; var argsSummary: String }
    struct Finished: Equatable {
        var seq: Int; var tool: String; var isError: Bool; var summary: String
    }

    private let lock = NSLock()
    private(set) var sessions: [(file: String, toolCount: Int, groups: [String])] = []
    private(set) var starts: [Started] = []
    private(set) var finishes: [Finished] = []
    private(set) var ended = 0

    func sessionStart(servedFile: String, toolCount: Int, groups: [String]) {
        lock.lock(); defer { lock.unlock() }
        sessions.append((servedFile, toolCount, groups))
    }
    func toolStart(seq: Int, tool: String, argsSummary: String) {
        lock.lock(); defer { lock.unlock() }
        starts.append(.init(seq: seq, tool: tool, argsSummary: argsSummary))
    }
    func toolFinish(seq: Int, tool: String, durationMs: Int, isError: Bool, summary: String) {
        lock.lock(); defer { lock.unlock() }
        // durationMs is wall-clock and non-deterministic; assert only it's sane.
        #expect(durationMs >= 0)
        finishes.append(.init(seq: seq, tool: tool, isError: isError, summary: summary))
    }
    func sessionEnd() {
        lock.lock(); defer { lock.unlock() }
        ended += 1
    }
}

@Suite struct MCPEventSinkTests {

    private func server(_ sink: SpyEventSink) -> MCPServer {
        Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(eventSink: sink))
    }

    @Test func announcesSessionOnMake() {
        let sink = SpyEventSink()
        _ = server(sink)
        #expect(sink.sessions.count == 1)
        let s = sink.sessions[0]
        #expect(s.file == "untitled")           // fixture session has no sourceURL
        #expect(s.toolCount > 0)
        #expect(s.groups == ToolGroup.allCases.map(\.rawValue).sorted())
    }

    @Test func announcesServedFileName() {
        let sink = SpyEventSink()
        let session = EditSession(
            snapshot: Fixtures.snapshot(),
            sourceURL: URL(fileURLWithPath: "/tmp/robot.usdz"))
        _ = AgentMCPServer.make(session: session, configuration: .init(eventSink: sink))
        #expect(sink.sessions.first?.file == "robot.usdz")
    }

    @Test func firesStartAndFinishOnSuccess() async {
        let sink = SpyEventSink()
        let server = server(sink)
        _ = await callOK(server, "scene_stats")
        #expect(sink.starts == [.init(seq: 1, tool: "scene_stats", argsSummary: "{}")])
        #expect(sink.finishes.count == 1)
        #expect(sink.finishes[0].seq == 1)
        #expect(sink.finishes[0].isError == false)
        #expect(!sink.finishes[0].summary.isEmpty)
    }

    @Test func firesFinishWithErrorOnToolError() async {
        let sink = SpyEventSink()
        let server = server(sink)
        // Missing required 'path' → a ToolError from the mutate tool.
        _ = await callError(server, "get_prim")
        #expect(sink.starts.count == 1)
        #expect(sink.finishes.count == 1)
        #expect(sink.finishes[0].isError == true)
        #expect(!sink.finishes[0].summary.isEmpty)
    }

    @Test func seqIncrementsAcrossCalls() async {
        let sink = SpyEventSink()
        let server = server(sink)
        _ = await callOK(server, "scene_stats")
        _ = await callOK(server, "scene_stats")
        #expect(sink.starts.map(\.seq) == [1, 2])
        #expect(sink.finishes.map(\.seq) == [1, 2])
    }

    @Test func unresolvedToolFiresNothing() async {
        let sink = SpyEventSink()
        let server = server(sink)
        _ = await call(server, "no_such_tool")
        #expect(sink.starts.isEmpty)
        #expect(sink.finishes.isEmpty)
    }

    @Test func summarizeBoundsLength() {
        let short = JSONValue.string("hi")
        #expect(MCPServer.summarize(short) == "\"hi\"")
        let long = String(repeating: "x", count: 500)
        let out = MCPServer.summarize(.string(long), maxLength: 10)
        #expect(out.count == 11)               // 10 chars + ellipsis
        #expect(out.hasSuffix("…"))
    }

    @Test func truncatePassesShortStrings() {
        #expect(MCPServer.truncate("abc", maxLength: 10) == "abc")
        #expect(MCPServer.truncate("abcdef", maxLength: 3) == "abc…")
    }

    @Test func elapsedMsIsNonNegative() {
        #expect(MCPServer.elapsedMs(since: DispatchTime.now()) >= 0)
    }
}
