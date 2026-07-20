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
}
