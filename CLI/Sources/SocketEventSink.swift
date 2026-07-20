import AgentMCP
import Foundation
import Network

/// The app's discovery record, written to
/// `~/Library/Application Support/OpenUSDZEditor/mcp/endpoint.json` while the
/// editor is running. The sink reads it to find the localhost activity port.
struct MCPEndpointInfo: Codable, Equatable {
    var port: Int
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

/// Shared location of the app's endpoint-discovery file.
enum MCPActivityPaths {
    static func endpointURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("OpenUSDZEditor", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("endpoint.json", isDirectory: false)
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
    private var connection: NWConnection?
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

    // coverage:disable — real localhost socket IO + reconnect/liveness. The wire
    // encoding (`encodeLine`) and endpoint parsing (`readEndpoint`) are unit-tested;
    // exercising NWConnection requires a live listener, covered by the end-to-end
    // verification recipe, not in-process unit tests.
    private func deliver(_ event: WireEvent) {
        let line = Self.encodeLine(event)
        lock.lock()
        let conn = connection ?? openConnection()
        lock.unlock()
        guard let conn else { return }
        conn.send(content: line, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.dropConnection() }
        })
    }

    /// Resolve the endpoint, verify the app process is alive, and open a
    /// connection. Returns nil (no-op) when the app isn't reachable.
    private func openConnection() -> NWConnection? {
        guard let info = Self.readEndpoint(from: endpointURL),
              isProcessAlive(info.pid),
              let port = NWEndpoint.Port(rawValue: UInt16(info.port))
        else { return nil }
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.dropConnection()
            case .ready: self?.resendSession()
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
        connection = conn
        return conn
    }

    /// On a fresh connection, replay `session_start` so a late-launched app
    /// still learns what's being served.
    private func resendSession() {
        lock.lock()
        let session = lastSession
        lock.unlock()
        guard let session else { return }
        connection?.send(content: Self.encodeLine(session), completion: .idempotent)
    }

    private func dropConnection() {
        lock.lock()
        connection?.cancel()
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
