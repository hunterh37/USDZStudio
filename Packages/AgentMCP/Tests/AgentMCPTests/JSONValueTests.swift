import Foundation
import Testing
@testable import AgentMCP

@Suite struct JSONValueTests {

    @Test func literalsAndAccessors() {
        let value: JSONValue = [
            "null": nil, "flag": true, "count": 3, "ratio": 1.5,
            "name": "box", "list": [1, 2, 3],
        ]
        #expect(value["null"].isNull)
        #expect(value["flag"].boolValue == true)
        #expect(value["count"].intValue == 3)
        #expect(value["count"].doubleValue == 3)
        #expect(value["ratio"].doubleValue == 1.5)
        #expect(value["ratio"].intValue == nil)
        #expect(value["name"].stringValue == "box")
        #expect(value["list"].arrayValue?.count == 3)
        #expect(value["missing"].isNull)
        #expect(value.objectValue?.count == 6)
        #expect(JSONValue.number(2).objectValue == nil)
        #expect(JSONValue.string("x").arrayValue == nil)
        #expect(JSONValue.bool(true).stringValue == nil)
        #expect(JSONValue.null.boolValue == nil)
        #expect(JSONValue.array([]).doubleValue == nil)
    }

    @Test func typedArrayAccessors() {
        #expect(JSONValue.array([1, 2.5]).doubleArrayValue == [1, 2.5])
        #expect(JSONValue.array([1, "x"]).doubleArrayValue == nil)
        #expect(JSONValue.string("nope").doubleArrayValue == nil)
        #expect(JSONValue.array([1, 2]).intArrayValue == [1, 2])
        #expect(JSONValue.array([1.5]).intArrayValue == nil)
        #expect(JSONValue.array(["a", "b"]).stringArrayValue == ["a", "b"])
        #expect(JSONValue.array(["a", 1]).stringArrayValue == nil)
        #expect(JSONValue.null.intArrayValue == nil)
        #expect(JSONValue.null.stringArrayValue == nil)
    }

    @Test func codableRoundTrip() throws {
        let original: JSONValue = [
            "nested": ["a": [true, nil, "s", 4, 4.25]],
            "n": -12,
        ]
        let decoded = try JSONValue.parse(original.serialized())
        #expect(decoded == original)
        // Integral numbers encode without a fraction.
        #expect(JSONValue.number(5).serializedString == "5")
        #expect(JSONValue.number(5.5).serializedString == "5.5")
        #expect(JSONValue.number(1e16).serializedString.contains("e+16") == true
                    || JSONValue.number(1e16).serializedString == "10000000000000000")
    }

    @Test func parseRejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try JSONValue.parse(Data("{not json".utf8))
        }
    }
}

@Suite struct JSONRPCTests {

    @Test func parsesRequestAndNotification() throws {
        let request = try JSONRPCRequest.parse(Data(
            #"{"jsonrpc":"2.0","id":7,"method":"ping","params":{"a":1}}"#.utf8))
        #expect(request.id == .number(7))
        #expect(request.method == "ping")
        #expect(request.params["a"].intValue == 1)

        let note = try JSONRPCRequest.parse(Data(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(note.id == nil)
        #expect(note.params == .object([:]))
    }

    @Test func rejectsMalformedRequests() {
        #expect(throws: JSONRPCError.self) {
            _ = try JSONRPCRequest.parse(Data("[[[".utf8))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try JSONRPCRequest.parse(Data("[1]".utf8))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try JSONRPCRequest.parse(Data(#"{"jsonrpc":"1.0","method":"m"}"#.utf8))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try JSONRPCRequest.parse(Data(#"{"jsonrpc":"2.0"}"#.utf8))
        }
        #expect(throws: JSONRPCError.self) {
            _ = try JSONRPCRequest.parse(Data(#"{"jsonrpc":"2.0","method":"m","id":true}"#.utf8))
        }
    }

    @Test func errorEnvelopes() {
        let error = JSONRPCError.invalidParams("bad", data: .string("detail"))
        let envelope = JSONRPCResponse.failure(id: nil, error: error)
        #expect(envelope["id"].isNull)
        #expect(envelope["error"]["code"].intValue == -32602)
        #expect(envelope["error"]["data"].stringValue == "detail")
        #expect(JSONRPCError.parseError("x").code == -32700)
        #expect(JSONRPCError.invalidRequest("x").code == -32600)
        #expect(JSONRPCError.methodNotFound("m").message.contains("m"))
        #expect(JSONRPCError.internalError("x").code == -32603)

        let ok = JSONRPCResponse.result(id: .number(3), result: .bool(true))
        #expect(ok["result"].boolValue == true)
    }
}
