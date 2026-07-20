import Foundation

/// Observation hook for a live activity feed of MCP tool calls
/// (docs/AGENT_MCP_PLAN.md — the app renders this in its activity panel).
///
/// AgentMCP only *fires* these callbacks; it deliberately owns no
/// serialization or transport. Dependency-lint forbids the app and
/// `EditorUI` from importing this package, so the JSON wire format — not a
/// shared Swift type — is the cross-process contract. The concrete sink that
/// encodes NDJSON and pushes it over a localhost socket lives in the `CLI`
/// target (the only module allowed to depend on AgentMCP).
///
/// Implementations MUST be non-blocking: `callTool` invokes them synchronously
/// on the tool-execution path, so a slow or absent transport must never stall a
/// tool call. Fire-and-forget (enqueue + async send) is the contract.
public protocol MCPEventSink: Sendable {
    /// A server began serving `servedFile` with `toolCount` tools enabled.
    func sessionStart(servedFile: String, toolCount: Int, groups: [String])
    /// A tool call started. `seq` increases monotonically within a session.
    func toolStart(seq: Int, tool: String, argsSummary: String)
    /// A tool call finished (or failed). `durationMs` is wall-clock elapsed.
    func toolFinish(seq: Int, tool: String, durationMs: Int, isError: Bool, summary: String)
    /// The session is ending (clean shutdown).
    func sessionEnd()
}
