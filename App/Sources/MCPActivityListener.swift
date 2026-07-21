import AgentMCP
import EditorUI
import Foundation
import USDCore

/// App-side mirror of the NDJSON activity protocol pushed by `openusdz mcp`.
/// Dependency-lint forbids the app from importing AgentMCP, so this is a
/// separate decode of the same wire contract (docs/AGENT_MCP_PLAN.md).
struct InboundEvent: Decodable {
    var type: String
    var pid: Int
    var ts: Int? = nil
    var protocolVersion: String? = nil
    var servedFile: String? = nil
    var toolCount: Int? = nil
    var groups: [String]? = nil
    var seq: Int? = nil
    var tool: String? = nil
    var argsSummary: String? = nil
    var durationMs: Int? = nil
    var isError: Bool? = nil
    var summary: String? = nil
}

/// One JSON-RPC relay frame from `openusdz mcp` running as a pump: the request
/// carries a correlation `id` and the raw JSON-RPC `line` (specs/agent-live-editing.md).
struct RpcRequestFrame: Decodable {
    var type: String
    var id: Int
    var line: String
}

/// The app's reply on the same socket: the JSON-RPC response `line` (empty for
/// notifications), tagged with the request `id`.
struct RpcResponseFrame: Encodable {
    var v = 1
    var type = "rpc_response"
    var id: Int
    var line: String
}

/// The editor's discovery record, written while the app runs so an
/// independently-spawned `openusdz mcp` can find the editor's UNIX-domain
/// socket. The transport is AF_UNIX (a file path), not loopback TCP: `port` is
/// replaced by `socketPath`; `pid`/`token` (liveness) are unchanged.
struct EndpointRecord: Codable {
    var socketPath: String
    var pid: Int
    var token: String
}

/// Hosts a localhost NDJSON listener that receives live tool-call activity from
/// `openusdz mcp` and drives the shared `MCPActivityModel` the UI observes.
/// Lives in the (un-coverage-gated) app target because it owns app-lifecycle
/// networking; the pure reducer `apply(_:)` is unit-tested with synthetic events.
@MainActor
final class MCPActivityListener: ObservableObject {
    /// Presentational state observed by the activity panel + menu-bar tray.
    let model = MCPActivityModel()

    /// Most recent tool calls kept in the panel.
    private let maxRows = 200
    private var server: UnixSocketServer?
    private let token = UUID().uuidString

    private static func mcpDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenUSDZEditor", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
    }

    /// Discovery-file location (mirrors the CLI sink's path).
    static func endpointURL() -> URL {
        mcpDirectory().appendingPathComponent("endpoint.json", isDirectory: false)
    }

    /// The AF_UNIX socket path the pump connects to.
    static func socketURL() -> URL {
        mcpDirectory().appendingPathComponent("agent.sock", isDirectory: false)
    }

    // MARK: Lifecycle

    private var listenerRetries = 0
    private let maxListenerRetries = 6

    func start() {
        guard server == nil else { return }
        let socketPath = Self.socketURL().path
        try? FileManager.default.createDirectory(
            at: Self.mcpDirectory(), withIntermediateDirectories: true)
        // Remove a stale socket file left by a dead (or our own prior) instance,
        // but never steal one a different live instance still owns.
        cleanupStaleSocket(at: socketPath)

        let server = UnixSocketServer()
        let ok = server.start(
            path: socketPath,
            onLine: { [weak self] line, fd in
                Task { @MainActor in self?.ingest(line, from: fd) }
            },
            onDisconnect: { [weak self] _ in
                Task { @MainActor in self?.markDisconnected() }
            })
        guard ok else {
            NSLog("MCPActivityListener: failed to bind \(socketPath)")
            restartListener()
            return
        }
        self.server = server
        listenerRetries = 0
        writeEndpoint(socketPath: socketPath)
    }

    /// Unlink a leftover socket file whose owning pid is dead (or is us). Leaves
    /// a socket a *different* live instance owns untouched — that instance is the
    /// authority, and our bind will simply fail and back off.
    private func cleanupStaleSocket(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        if let data = try? Data(contentsOf: Self.endpointURL()),
           let record = try? JSONDecoder().decode(EndpointRecord.self, from: data),
           record.pid != selfPID,
           kill(pid_t(record.pid), 0) == 0 || errno == EPERM {
            return   // a different live instance owns it
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Bounded-backoff restart so a transient bind failure recovers instead of
    /// silently disabling agent connectivity.
    private func restartListener() {
        server?.stop()
        server = nil
        guard listenerRetries < maxListenerRetries else {
            NSLog("MCPActivityListener: giving up after \(maxListenerRetries) retries")
            return
        }
        listenerRetries += 1
        let delay = Double(listenerRetries) * 0.5   // 0.5s, 1.0s, … 3.0s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.start()
        }
    }

    func stop() {
        server?.stop()
        server = nil
        Self.removeEndpointIfOwned()
    }

    /// Remove the discovery file + socket only if this process still owns them.
    /// A second instance that never became the endpoint owner (its bind lost the
    /// race and backed off) must not delete the first instance's endpoint on quit.
    static func removeEndpointIfOwned() {
        let url = endpointURL()
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(EndpointRecord.self, from: data),
              record.pid == Int(ProcessInfo.processInfo.processIdentifier)
        else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: socketURL().path)
    }

    private func writeEndpoint(socketPath: String) {
        let record = EndpointRecord(
            socketPath: socketPath,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            token: token)
        let url = Self.endpointURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Connection handling

    private func ingest(_ line: Data, from fd: Int32) {
        // A relay request (editor hosts the server) takes priority; anything
        // else is legacy activity from an in-process CLI server.
        if let frame = try? JSONDecoder().decode(RpcRequestFrame.self, from: line),
           frame.type == "rpc_request" {
            handleRpc(frame, on: fd)
        } else if let event = try? JSONDecoder().decode(InboundEvent.self, from: line) {
            apply(event)
        }
    }

    // MARK: In-app MCP host (specs/agent-live-editing.md)

    private var hostSession: EditSession?
    private var hostServer: MCPServer?
    private weak var boundDocument: EditorDocument?

    /// Bind (or rebind) the hosted editing session to the front document. The
    /// session runs on its own stage seeded from the document; after each agent
    /// request its result is mirrored into the live document (which refreshes
    /// the viewport). Rebinding starts a fresh agent session.
    func bindDocument(_ document: EditorDocument?) {
        boundDocument = document
        guard let document else { hostSession = nil; hostServer = nil; return }
        let session = EditSession(snapshot: document.snapshot, strictness: .warn)
        let hostPID = Int(ProcessInfo.processInfo.processIdentifier)
        let sink = HostActivitySink(pid: hostPID) { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        hostSession = session
        hostServer = AgentMCPServer.make(
            session: session,
            configuration: AgentMCPServer.Configuration(eventSink: sink))
    }

    /// Run one relayed JSON-RPC request against the hosted server, mirror the
    /// resulting stage into the live document, and reply on the same socket.
    private func handleRpc(_ frame: RpcRequestFrame, on fd: Int32) {
        guard let hostServer, let session = hostSession else {
            send(RpcResponseFrame(id: frame.id, line: ""), on: fd)
            return
        }
        Task { @MainActor in
            let response = await hostServer.handle(data: Data(frame.line.utf8))
            // Mirror agent edits into the open document → viewport refresh.
            boundDocument?.applyConsoleEdit(
                after: session.stage.currentSnapshot, label: "Agent Edit")
            send(RpcResponseFrame(id: frame.id, line: response?.serializedString ?? ""), on: fd)
        }
    }

    private func send(_ frame: RpcResponseFrame, on fd: Int32) {
        guard var data = try? JSONEncoder().encode(frame) else { return }
        data.append(0x0A)
        server?.send(data, to: fd)
    }

    // MARK: Pure reducer (unit-tested)

    /// Fold one decoded event into the presentational model.
    func apply(_ event: InboundEvent) {
        switch event.type {
        case "session_start":
            model.isConnected = true
            model.servedFile = event.servedFile
            model.toolCount = event.toolCount ?? 0
            model.groups = event.groups ?? []
            if model.connectedSince == nil { model.connectedSince = Date() }

        case "tool_started":
            guard let seq = event.seq, let tool = event.tool else { return }
            let row = MCPCallRow(
                pid: event.pid, seq: seq, tool: tool, status: .running,
                summary: event.argsSummary ?? "")
            model.rows.insert(row, at: 0)
            if model.rows.count > maxRows { model.rows.removeLast(model.rows.count - maxRows) }

        case "tool_finished":
            guard let seq = event.seq else { return }
            let id = "\(event.pid)-\(seq)"
            if let index = model.rows.firstIndex(where: { $0.id == id }) {
                model.rows[index].status = (event.isError == true) ? .error : .success
                model.rows[index].durationMs = event.durationMs
                model.rows[index].summary = event.summary ?? model.rows[index].summary
            }

        case "session_end":
            markDisconnected()

        default:
            break  // heartbeat / unknown types: no state change
        }
    }

    func markDisconnected() {
        model.isConnected = false
        model.connectedSince = nil
    }
}

/// Adapts the hosted server's `MCPEventSink` callbacks into the app's
/// `InboundEvent` reducer, so the activity panel reflects the in-app host the
/// same way it reflected the out-of-process CLI server.
final class HostActivitySink: MCPEventSink, @unchecked Sendable {
    let pid: Int
    let forward: @Sendable (InboundEvent) -> Void

    init(pid: Int, forward: @escaping @Sendable (InboundEvent) -> Void) {
        self.pid = pid
        self.forward = forward
    }

    func sessionStart(servedFile: String, toolCount: Int, groups: [String]) {
        forward(InboundEvent(type: "session_start", pid: pid,
                             servedFile: servedFile, toolCount: toolCount, groups: groups))
    }
    func toolStart(seq: Int, tool: String, argsSummary: String) {
        forward(InboundEvent(type: "tool_started", pid: pid,
                             seq: seq, tool: tool, argsSummary: argsSummary))
    }
    func toolFinish(seq: Int, tool: String, durationMs: Int, isError: Bool, summary: String) {
        forward(InboundEvent(type: "tool_finished", pid: pid,
                             seq: seq, durationMs: durationMs, isError: isError, summary: summary))
    }
    func sessionEnd() {
        forward(InboundEvent(type: "session_end", pid: pid))
    }
}
