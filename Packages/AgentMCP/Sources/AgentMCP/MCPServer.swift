import Foundation

/// Tool group for per-session activation (docs/AGENT_MCP_PLAN.md §6 —
/// "Tool groups, activated per session": a client can request a lean
/// profile, e.g. read+verify only for an audit agent).
public enum ToolGroup: String, Sendable, CaseIterable {
    case read, mutate, verify, render, asset, script, transaction
}

/// One typed MCP tool: name, JSON-Schema input contract, and handler.
public struct MCPTool: Sendable {
    public var name: String
    public var group: ToolGroup
    public var description: String
    public var inputSchema: JSONValue
    public var handler: @Sendable (JSONValue) async throws -> JSONValue

    public init(
        name: String, group: ToolGroup, description: String,
        inputSchema: JSONValue,
        handler: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.name = name
        self.group = group
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// Read-only MCP resource (plan §3.1 — `usd://scene`, `usd://stats`, …).
public struct MCPResource: Sendable {
    public var uri: String
    public var name: String
    public var description: String
    public var provider: @Sendable () -> JSONValue

    public init(
        uri: String, name: String, description: String,
        provider: @escaping @Sendable () -> JSONValue
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.provider = provider
    }
}

/// Workflow-recipe prompt (plan §6 — RTX Remix's multi-step templates).
public struct MCPPrompt: Sendable {
    public var name: String
    public var description: String
    public var text: String

    public init(name: String, description: String, text: String) {
        self.name = name
        self.description = description
        self.text = text
    }
}

/// Transport-agnostic MCP server core. The stdio loop (or a future
/// streamable-HTTP adapter, plan §7 "Transport") feeds it one JSON-RPC
/// message at a time; it returns the response envelope, or `nil` for
/// notifications. No editing logic lives here — it's a thin adapter over
/// the registered tools (plan §2).
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"

    public let serverName: String
    public let serverVersion: String
    private var tools: [MCPTool] = []
    private var resources: [MCPResource] = []
    private var prompts: [MCPPrompt] = []
    private let enabledGroups: Set<ToolGroup>

    /// Optional live-activity observer (docs/AGENT_MCP_PLAN.md). Fired on every
    /// tool call; nil in headless/test contexts with no observer attached.
    private var eventSink: (any MCPEventSink)?
    /// Monotonic per-session tool-call counter handed to the sink as `seq`.
    private var toolSeq = 0

    public init(
        serverName: String = "openusdz-agent",
        serverVersion: String = "0.1.0",
        enabledGroups: Set<ToolGroup> = Set(ToolGroup.allCases),
        eventSink: (any MCPEventSink)? = nil
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.enabledGroups = enabledGroups
        self.eventSink = eventSink
    }

    /// Register a tool; silently skipped when its group isn't enabled.
    public func register(_ tool: MCPTool) {
        guard enabledGroups.contains(tool.group) else { return }
        tools.append(tool)
    }

    public func register(_ resource: MCPResource) { resources.append(resource) }
    public func register(_ prompt: MCPPrompt) { prompts.append(prompt) }

    public var toolNames: [String] { tools.map(\.name) }

    // MARK: - Dispatch

    /// Handle one raw JSON-RPC message. Returns the response envelope, or
    /// `nil` when the message is a notification.
    public func handle(data: Data) async -> JSONValue? {
        let request: JSONRPCRequest
        do {
            request = try JSONRPCRequest.parse(data)
        } catch let error as JSONRPCError {
            return JSONRPCResponse.failure(id: nil, error: error)
        } catch {
            // coverage:disable — defensive: JSONRPCRequest.parse only throws JSONRPCError; kept so a future parse change still yields a spec-shaped error.
            return JSONRPCResponse.failure(id: nil, error: .parseError("\(error)"))
            // coverage:enable
        }
        return await handle(request: request)
    }

    public func handle(request: JSONRPCRequest) async -> JSONValue? {
        // Notifications get no response.
        guard let id = request.id, !id.isNull else {
            return nil
        }
        do {
            let result = try await dispatch(request)
            return JSONRPCResponse.result(id: id, result: result)
        } catch let error as JSONRPCError {
            return JSONRPCResponse.failure(id: id, error: error)
        } catch {
            // coverage:disable — defensive: dispatch() only throws JSONRPCError (tool failures are isError results, not throws); kept as the last-resort protocol error.
            return JSONRPCResponse.failure(id: id, error: .internalError("\(error)"))
            // coverage:enable
        }
    }

    private func dispatch(_ request: JSONRPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            return .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([
                    "tools": .object([:]),
                    "resources": .object([:]),
                    "prompts": .object([:]),
                ]),
                "serverInfo": .object([
                    "name": .string(serverName),
                    "version": .string(serverVersion),
                ]),
            ])

        case "ping":
            return .object([:])

        case "tools/list":
            return .object([
                "tools": .array(tools.map { tool in
                    .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "inputSchema": tool.inputSchema,
                    ])
                })
            ])

        case "tools/call":
            return await callTool(request.params)

        case "resources/list":
            return .object([
                "resources": .array(resources.map { r in
                    .object([
                        "uri": .string(r.uri),
                        "name": .string(r.name),
                        "description": .string(r.description),
                        "mimeType": "application/json",
                    ])
                })
            ])

        case "resources/read":
            guard let uri = request.params["uri"].stringValue else {
                throw JSONRPCError.invalidParams("missing 'uri'")
            }
            guard let resource = resources.first(where: { $0.uri == uri }) else {
                throw JSONRPCError.invalidParams("unknown resource '\(uri)'")
            }
            return .object([
                "contents": .array([
                    .object([
                        "uri": .string(uri),
                        "mimeType": "application/json",
                        "text": .string(resource.provider().serializedString),
                    ])
                ])
            ])

        case "prompts/list":
            return .object([
                "prompts": .array(prompts.map { p in
                    .object(["name": .string(p.name), "description": .string(p.description)])
                })
            ])

        case "prompts/get":
            guard let name = request.params["name"].stringValue,
                  let prompt = prompts.first(where: { $0.name == name })
            else {
                throw JSONRPCError.invalidParams("unknown prompt")
            }
            return .object([
                "description": .string(prompt.description),
                "messages": .array([
                    .object([
                        "role": "user",
                        "content": .object(["type": "text", "text": .string(prompt.text)]),
                    ])
                ]),
            ])

        default:
            throw JSONRPCError.methodNotFound(request.method)
        }
    }

    /// tools/call — tool failures come back as `isError` tool results
    /// (structured, correctable), not protocol errors.
    private func callTool(_ params: JSONValue) async -> JSONValue {
        guard let name = params["name"].stringValue else {
            return Self.toolFailure("missing tool 'name'")
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return Self.toolFailure("unknown tool '\(name)' (enabled groups: \(enabledGroups.map(\.rawValue).sorted().joined(separator: ",")))")
        }
        toolSeq += 1
        let seq = toolSeq
        let started = DispatchTime.now()
        eventSink?.toolStart(seq: seq, tool: name, argsSummary: Self.summarize(params["arguments"]))
        do {
            let result = try await tool.handler(params["arguments"])
            eventSink?.toolFinish(
                seq: seq, tool: name, durationMs: Self.elapsedMs(since: started),
                isError: false, summary: Self.summarize(result))
            return .object([
                "content": .array([
                    .object(["type": "text", "text": .string(result.serializedString)])
                ]),
                "structuredContent": result,
                "isError": .bool(false),
            ])
        } catch let error as ToolError {
            let message = "\(error)"
            eventSink?.toolFinish(
                seq: seq, tool: name, durationMs: Self.elapsedMs(since: started),
                isError: true, summary: Self.truncate(message))
            return Self.toolFailure(message)
        } catch {
            let message = "internal error: \(error)"
            eventSink?.toolFinish(
                seq: seq, tool: name, durationMs: Self.elapsedMs(since: started),
                isError: true, summary: Self.truncate(message))
            return Self.toolFailure(message)
        }
    }

    static func toolFailure(_ message: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": "text", "text": .string(message)])]),
            "isError": .bool(true),
        ])
    }

    /// Fire `sessionStart` on the attached sink (called once the server is
    /// assembled, so `toolCount`/`groups` are final).
    func announceSession(servedFile: String, groups: [String]) {
        eventSink?.sessionStart(servedFile: servedFile, toolCount: tools.count, groups: groups)
    }

    // MARK: - Activity-summary helpers (pure)

    /// Compact, length-bounded rendering of a tool's arguments or result for
    /// the activity feed — never the full payload.
    static func summarize(_ value: JSONValue, maxLength: Int = 200) -> String {
        truncate(value.serializedString, maxLength: maxLength)
    }

    /// Truncate `text` to `maxLength` characters, appending an ellipsis when cut.
    static func truncate(_ text: String, maxLength: Int = 200) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    /// Wall-clock milliseconds elapsed since `start`.
    static func elapsedMs(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}
