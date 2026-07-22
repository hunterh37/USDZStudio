import AgentMCP
import Foundation

/// The app's discovery record, written to
/// `~/Library/Application Support/OpenUSDZEditor/mcp/endpoint.json` while the
/// editor is running. The sink reads it to find the editor's UNIX-domain socket.
///
/// The transport is an AF_UNIX socket (a file path), not loopback TCP: `port`
/// is gone, replaced by `socketPath`. `pid`/`token` (liveness) are unchanged.
struct MCPEndpointInfo: Codable, Equatable {
    var socketPath: String
    var pid: Int
    var token: String?
}

/// One line of the NDJSON activity protocol (docs/AGENT_MCP_PLAN.md). Optional
/// fields are omitted when nil (synthesized `encodeIfPresent`), so each event
/// type carries only its own keys. This is the cross-process contract — the app
/// decodes the same shape with its own mirror type.
struct WireEvent: Encodable, Equatable {
    var v = 1
    var type: String
    var pid: Int
    var ts: Int
    var protocolVersion: String?
    var servedFile: String?
    var toolCount: Int?
    var groups: [String]?
    var seq: Int?
    var tool: String?
    var argsSummary: String?
    var durationMs: Int?
    var isError: Bool?
    var summary: String?
}

/// Shared location of the app's endpoint-discovery file and UNIX socket.
enum MCPActivityPaths {
    /// Directory holding both the discovery file and the socket.
    static func mcpDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("OpenUSDZEditor", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
    }

    static func endpointURL(fileManager: FileManager = .default) -> URL {
        mcpDirectory(fileManager: fileManager)
            .appendingPathComponent("endpoint.json", isDirectory: false)
    }

    /// The AF_UNIX socket the editor binds and the pump connects to.
    static func socketURL(fileManager: FileManager = .default) -> URL {
        mcpDirectory(fileManager: fileManager)
            .appendingPathComponent("agent.sock", isDirectory: false)
    }

    /// The reference-image hand-off file. A CLI-hosted session writes the
    /// agent's reference here so an editor launched afterwards can restore it
    /// (specs/agent-live-editing.md — "Reference panel").
    static func referenceURL(fileManager: FileManager = .default) -> URL {
        mcpDirectory(fileManager: fileManager)
            .appendingPathComponent("reference.json", isDirectory: false)
    }
}

/// `MCPEventSink` that pushes NDJSON activity lines to the running editor over a
/// localhost socket. Constructed in `McpCommand.run` (the coverage-disabled
/// composition root); the pure seams — endpoint parsing and line encoding — are
/// unit-tested. When the app isn't running (no/stale endpoint, connection
/// refused) every method is a graceful no-op and never blocks the tool path.
final class SocketEventSink: MCPEventSink, @unchecked Sendable {
    private let endpointURL: URL
    private let pid: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "openusdz.activity-sink")
    private var connection: UnixSocketClient?
    private var lastSession: WireEvent?

    init(endpointURL: URL = MCPActivityPaths.endpointURL(),
         pid: Int = Int(ProcessInfo.processInfo.processIdentifier)) {
        self.endpointURL = endpointURL
        self.pid = pid
    }

    // MARK: Pure, unit-tested seams

    /// Decode the app's endpoint file; nil when absent or malformed.
    static func readEndpoint(from url: URL) -> MCPEndpointInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MCPEndpointInfo.self, from: data)
    }

    /// Encode one event as a single newline-terminated NDJSON line.
    static func encodeLine(_ event: WireEvent) -> Data {
        var data = (try? JSONEncoder().encode(event)) ?? Data()
        data.append(0x0A)  // '\n'
        return data
    }

    private func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    // MARK: MCPEventSink

    func sessionStart(servedFile: String, toolCount: Int, groups: [String]) {
        let event = WireEvent(
            type: "session_start", pid: pid, ts: now(),
            protocolVersion: MCPServer.protocolVersion,
            servedFile: servedFile, toolCount: toolCount, groups: groups)
        lock.lock(); lastSession = event; lock.unlock()
        deliver(event)
    }

    func toolStart(seq: Int, tool: String, argsSummary: String) {
        deliver(WireEvent(
            type: "tool_started", pid: pid, ts: now(),
            seq: seq, tool: tool, argsSummary: argsSummary))
    }

    func toolFinish(seq: Int, tool: String, durationMs: Int, isError: Bool, summary: String) {
        deliver(WireEvent(
            type: "tool_finished", pid: pid, ts: now(),
            seq: seq, tool: tool, durationMs: durationMs,
            isError: isError, summary: summary))
    }

    func sessionEnd() {
        deliver(WireEvent(type: "session_end", pid: pid, ts: now()))
        close()
    }

    // coverage:disable — real AF_UNIX socket IO + reconnect/liveness. The wire
    // encoding (`encodeLine`) and endpoint parsing (`readEndpoint`) are unit-tested;
    // exercising a live UNIX socket requires a listening editor, covered by the
    // end-to-end verification recipe, not in-process unit tests.
    private func deliver(_ event: WireEvent) {
        let line = Self.encodeLine(event)
        lock.lock()
        let conn = connection ?? openConnection()
        lock.unlock()
        guard let conn else { return }
        conn.send(line)
    }

    /// Resolve the endpoint, verify the app process is alive, and open a
    /// UNIX-domain connection. Returns nil (no-op) when the app isn't reachable.
    /// Caller holds `lock`.
    private func openConnection() -> UnixSocketClient? {
        guard let info = Self.readEndpoint(from: endpointURL),
              isProcessAlive(info.pid),
              !info.socketPath.isEmpty,
              let conn = UnixSocketClient.connect(path: info.socketPath, queue: queue)
        else { return nil }
        conn.startReceiving(onData: { _ in }, onClose: { [weak self] in self?.dropConnection() })
        connection = conn
        // Replay `session_start` so a late-launched app still learns what's served.
        if let session = lastSession { conn.send(Self.encodeLine(session)) }
        return conn
    }

    private func dropConnection() {
        lock.lock()
        connection?.close()
        connection = nil
        lock.unlock()
    }

    private func close() {
        dropConnection()
    }

    private func isProcessAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
    // coverage:enable
}
