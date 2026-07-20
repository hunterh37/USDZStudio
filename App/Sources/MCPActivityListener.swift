import EditorUI
import Foundation
import Network

/// App-side mirror of the NDJSON activity protocol pushed by `openusdz mcp`.
/// Dependency-lint forbids the app from importing AgentMCP, so this is a
/// separate decode of the same wire contract (docs/AGENT_MCP_PLAN.md).
struct InboundEvent: Decodable {
    var type: String
    var pid: Int
    var ts: Int?
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

/// The editor's discovery record, written while the app runs so an
/// independently-spawned `openusdz mcp` can find the localhost activity port.
struct EndpointRecord: Encodable {
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

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self else { return }
                Task { @MainActor in self.writeEndpoint() }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            // Listener unavailable (e.g. sandbox without entitlement) — the app
            // still runs; the activity feature is simply inert.
            NSLog("MCPActivityListener: failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: Self.endpointURL())
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
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? JSONDecoder().decode(InboundEvent.self, from: Data(line)) {
                apply(event)
            }
        }
        buffers[key] = buffer
    }

    private func connectionClosed(_ conn: NWConnection) {
        buffers[ObjectIdentifier(conn)] = nil
        markDisconnected()
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
