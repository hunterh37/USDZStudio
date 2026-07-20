import AgentMCP
import EditorUI
import Foundation
import Network
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
/// independently-spawned `openusdz mcp` can find the localhost activity port.
struct EndpointRecord: Codable {
    var port: Int
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
    private var listener: NWListener?
    private var buffers: [ObjectIdentifier: Data] = [:]
    private let token = UUID().uuidString

    /// Discovery-file location (mirrors the CLI sink's path).
    static func endpointURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenUSDZEditor", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("endpoint.json", isDirectory: false)
    }

    // MARK: Lifecycle

    private var listenerRetries = 0
    private let maxListenerRetries = 6

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listenerRetries = 0
                        self.writeEndpoint()
                    case .failed, .cancelled:
                        // A transient bind/ready failure must not leave the
                        // feature permanently inert — restart with backoff.
                        self.restartListener()
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            NSLog("MCPActivityListener: failed to start: \(error)")
            restartListener()
        }
    }

    /// Bounded-backoff restart so a slow/failed `NWListener` recovers instead of
    /// silently disabling agent connectivity.
    private func restartListener() {
        listener?.cancel()
        listener = nil
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
        listener?.cancel()
        listener = nil
        // Only remove the discovery file if it's still ours — otherwise a
        // second instance that has since taken over would be orphaned.
        let url = Self.endpointURL()
        if let data = try? Data(contentsOf: url),
           let record = try? JSONDecoder().decode(EndpointRecord.self, from: data),
           record.pid == Int(ProcessInfo.processInfo.processIdentifier) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeEndpoint() {
        guard let port = listener?.port?.rawValue else { return }
        let record = EndpointRecord(
            port: Int(port),
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

    nonisolated private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.connectionClosed(conn) }
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
        receive(on: conn)
    }

    nonisolated private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            // Hop to the main actor exactly once: consolidating the ingest,
            // close, and re-arm into a single @MainActor task keeps `self`'s
            // isolated state from being touched across concurrent hops (Swift 6
            // strict-concurrency: "sending 'self' risks data races").
            let closed = isComplete || error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty { self.ingest(data, from: conn) }
                if closed {
                    self.connectionClosed(conn)
                } else {
                    self.receive(on: conn)
                }
            }
        }
    }

    private func ingest(_ data: Data, from conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        var buffer = buffers[key] ?? Data()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            // A relay request (editor hosts the server) takes priority; anything
            // else is legacy activity from an in-process CLI server.
            if let frame = try? JSONDecoder().decode(RpcRequestFrame.self, from: line),
               frame.type == "rpc_request" {
                handleRpc(frame, on: conn)
            } else if let event = try? JSONDecoder().decode(InboundEvent.self, from: line) {
                apply(event)
            }
        }
        buffers[key] = buffer
    }

    private func connectionClosed(_ conn: NWConnection) {
        buffers[ObjectIdentifier(conn)] = nil
        markDisconnected()
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
    private func handleRpc(_ frame: RpcRequestFrame, on conn: NWConnection) {
        guard let server = hostServer, let session = hostSession else {
            send(RpcResponseFrame(id: frame.id, line: ""), on: conn)
            return
        }
        Task { @MainActor in
            let response = await server.handle(data: Data(frame.line.utf8))
            // Mirror agent edits into the open document → viewport refresh.
            boundDocument?.applyConsoleEdit(
                after: session.stage.currentSnapshot, label: "Agent Edit")
            send(RpcResponseFrame(id: frame.id, line: response?.serializedString ?? ""), on: conn)
        }
    }

    private func send(_ frame: RpcResponseFrame, on conn: NWConnection) {
        guard var data = try? JSONEncoder().encode(frame) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
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
