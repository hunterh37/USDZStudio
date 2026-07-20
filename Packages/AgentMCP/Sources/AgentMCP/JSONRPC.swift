import Foundation

/// JSON-RPC 2.0 message model for the MCP stdio transport
/// (docs/AGENT_MCP_PLAN.md §2 — "Agent (MCP client) │ JSON-RPC (stdio)").
public struct JSONRPCRequest: Sendable, Hashable {
    /// `nil` id means the message is a notification (no response expected).
    public var id: JSONValue?
    public var method: String
    public var params: JSONValue

    public init(id: JSONValue? = nil, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Parse one JSON-RPC request line. Throws `JSONRPCError` on malformed input.
    public static func parse(_ data: Data) throws -> JSONRPCRequest {
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw JSONRPCError.parseError("invalid JSON: \(error)")
        }
        guard let object = value.objectValue else {
            throw JSONRPCError.invalidRequest("request must be a JSON object")
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            throw JSONRPCError.invalidRequest("missing jsonrpc: \"2.0\"")
        }
        guard let method = object["method"]?.stringValue else {
            throw JSONRPCError.invalidRequest("missing method")
        }
        let id = object["id"]
        if let id, id.stringValue == nil, id.intValue == nil, !id.isNull {
            throw JSONRPCError.invalidRequest("id must be a string or number")
        }
        return JSONRPCRequest(id: id, method: method, params: object["params"] ?? .object([:]))
    }
}

/// Structured JSON-RPC error with the standard code space.
public struct JSONRPCError: Error, Sendable, Hashable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parseError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32700, message: message)
    }
    public static func invalidRequest(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32600, message: message)
    }
    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "method not found: \(method)")
    }
    public static func invalidParams(_ message: String, data: JSONValue? = nil) -> JSONRPCError {
        JSONRPCError(code: -32602, message: message, data: data)
    }
    public static func internalError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: message)
    }

    public var asJSON: JSONValue {
        var payload: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string(message),
        ]
        if let data { payload["data"] = data }
        return .object(payload)
    }
}

public enum JSONRPCResponse {
    /// Successful response envelope for a request id.
    public static func result(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Error response envelope. A `nil` id (parse failure) encodes as JSON null.
    public static func failure(id: JSONValue?, error: JSONRPCError) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id ?? .null, "error": error.asJSON])
    }
}
