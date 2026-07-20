import Foundation
import Testing
@testable import openusdz

@Suite struct SocketEventSinkTests {

    private func tempFile(_ contents: String?) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-endpoint-\(UUID().uuidString).json")
        if let contents { try? contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    // MARK: readEndpoint

    @Test func readsValidEndpoint() {
        let url = tempFile(#"{"port":54321,"pid":4242,"token":"abc"}"#)
        let info = SocketEventSink.readEndpoint(from: url)
        #expect(info == MCPEndpointInfo(port: 54321, pid: 4242, token: "abc"))
    }

    @Test func readsEndpointWithoutToken() {
        let url = tempFile(#"{"port":9,"pid":1}"#)
        #expect(SocketEventSink.readEndpoint(from: url)?.token == nil)
    }

    @Test func missingEndpointReturnsNil() {
        let url = tempFile(nil)  // never written
        #expect(SocketEventSink.readEndpoint(from: url) == nil)
    }

    @Test func malformedEndpointReturnsNil() {
        let url = tempFile("not json at all")
        #expect(SocketEventSink.readEndpoint(from: url) == nil)
    }

    // MARK: encodeLine

    @Test func encodesNewlineTerminatedJSON() throws {
        let event = WireEvent(
            type: "tool_started", pid: 7, ts: 1000, seq: 3,
            tool: "set_transform", argsSummary: "/Root tx=1")
        let data = SocketEventSink.encodeLine(event)
        #expect(data.last == 0x0A)
        let decoded = try JSONSerialization.jsonObject(
            with: data.dropLast()) as? [String: Any]
        #expect(decoded?["type"] as? String == "tool_started")
        #expect(decoded?["seq"] as? Int == 3)
        #expect(decoded?["tool"] as? String == "set_transform")
        #expect(decoded?["v"] as? Int == 1)
        // nil fields are omitted, not encoded as null.
        #expect(decoded?["durationMs"] == nil)
        #expect(decoded?.keys.contains("summary") == false)
    }

    @Test func encodesSessionStartFields() throws {
        let event = WireEvent(
            type: "session_start", pid: 5, ts: 2000,
            protocolVersion: "2025-06-18", servedFile: "robot.usdz",
            toolCount: 38, groups: ["read", "mutate"])
        let obj = try JSONSerialization.jsonObject(
            with: SocketEventSink.encodeLine(event).dropLast()) as? [String: Any]
        #expect(obj?["servedFile"] as? String == "robot.usdz")
        #expect(obj?["toolCount"] as? Int == 38)
        #expect(obj?["groups"] as? [String] == ["read", "mutate"])
    }

    // MARK: fire methods are graceful no-ops with no app running

    @Test func fireMethodsNoOpWithoutEndpoint() {
        let sink = SocketEventSink(endpointURL: tempFile(nil), pid: 123)
        // None of these should throw or block when the app isn't running.
        sink.sessionStart(servedFile: "x.usda", toolCount: 1, groups: ["read"])
        sink.toolStart(seq: 1, tool: "scene_stats", argsSummary: "{}")
        sink.toolFinish(seq: 1, tool: "scene_stats", durationMs: 5, isError: false, summary: "ok")
        sink.sessionEnd()
    }
}
