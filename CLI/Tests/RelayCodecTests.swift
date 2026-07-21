import Foundation
import Testing
@testable import openusdz

/// The pure relay frame codec (the IO pump itself is a coverage-disabled
/// composition root, verified end-to-end).
@Suite struct RelayCodecTests {

    @Test func requestRoundTripsThroughResponseShape() throws {
        let data = RelayCodec.encodeRequest(id: 7, line: "{\"jsonrpc\":\"2.0\"}")
        #expect(data.last == 0x0A)   // newline-terminated NDJSON
        // Re-decode as the request struct to confirm the fields.
        let noNL = data.dropLast()
        let req = try JSONDecoder().decode(RelayCodec.Request.self, from: Data(noNL))
        #expect(req.type == "rpc_request")
        #expect(req.id == 7)
        #expect(req.line.contains("jsonrpc"))
    }

    @Test func decodesResponseAndRejectsOtherFrames() throws {
        let good = Data("{\"type\":\"rpc_response\",\"id\":3,\"line\":\"{}\"}".utf8)
        let resp = RelayCodec.decodeResponse(good)
        #expect(resp?.id == 3)
        #expect(resp?.line == "{}")

        // Activity events and malformed lines are not responses.
        #expect(RelayCodec.decodeResponse(Data("{\"type\":\"tool_started\",\"id\":1,\"line\":\"\"}".utf8)) == nil)
        #expect(RelayCodec.decodeResponse(Data("not json".utf8)) == nil)
    }

    @Test func drainSplitsCompleteLinesAndKeepsRemainder() {
        let buffer = Data("{\"a\":1}\n{\"b\":2}\n{\"partial\"".utf8)
        let (lines, remainder) = RelayCodec.drainLines(buffer)
        #expect(lines.count == 2)
        #expect(String(decoding: lines[0], as: UTF8.self) == "{\"a\":1}")
        #expect(String(decoding: remainder, as: UTF8.self) == "{\"partial\"")

        // No trailing newline → nothing complete.
        let (none, rest) = RelayCodec.drainLines(Data("{\"x\"".utf8))
        #expect(none.isEmpty)
        #expect(rest.count == 4)
    }

    @Test func extractsJSONRPCIdFragmentAndNotifications() {
        #expect(RelayCodec.jsonrpcIDFragment("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"x\"}") == "4")
        #expect(RelayCodec.jsonrpcIDFragment("{\"id\":\"abc\",\"method\":\"x\"}") == "\"abc\"")
        // A notification has no id.
        #expect(RelayCodec.jsonrpcIDFragment("{\"jsonrpc\":\"2.0\",\"method\":\"notify\"}") == "null")
        #expect(RelayCodec.jsonrpcIDFragment("garbage") == "null")
        #expect(RelayCodec.isNotification("{\"method\":\"notify\"}"))
        #expect(!RelayCodec.isNotification("{\"id\":1,\"method\":\"x\"}"))
    }

    @Test func buildsSpecShapedErrorResponse() throws {
        let line = RelayCodec.errorResponse(idFragment: "4", code: -32001, message: "editor \"gone\"")
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(obj?["jsonrpc"] as? String == "2.0")
        #expect(obj?["id"] as? Int == 4)
        let err = obj?["error"] as? [String: Any]
        #expect(err?["code"] as? Int == -32001)
        #expect((err?["message"] as? String)?.contains("gone") == true)   // quotes survived escaping
    }

    @Test func awaitEndpointRetriesUntilLiveThenGivesUp() {
        // Appears on the 3rd probe → found, with 2 ticks spent waiting.
        var probes = 0, ticks = 0
        let info = RelayCodec.awaitEndpoint(
            attempts: 5,
            resolve: { probes += 1; return probes >= 3 ? MCPEndpointInfo(socketPath: "/tmp/a.sock", pid: 1, token: nil) : nil },
            tick: { ticks += 1 })
        #expect(info?.socketPath == "/tmp/a.sock")
        #expect(probes == 3)
        #expect(ticks == 2)

        // Never appears → nil after exactly `attempts` probes, no trailing tick.
        var p = 0, t = 0
        let none = RelayCodec.awaitEndpoint(attempts: 3, resolve: { p += 1; return nil }, tick: { t += 1 })
        #expect(none == nil)
        #expect(p == 3)
        #expect(t == 2)
    }
}
