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

    /// The agent's reference image, observed by the reference panel above the
    /// inspector. Updated as the in-app host handles `set_reference_image`, and
    /// seeded on launch from the hand-off file so an image set before this
    /// window existed (agent/CLI-driven launch) is restored
    /// (specs/agent-live-editing.md — "Reference panel").
    let referenceModel = ReferenceImageModel()

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

    /// The reference-image hand-off file (mirrors the CLI sink's path).
    static func referenceURL() -> URL {
        mcpDirectory().appendingPathComponent("reference.json", isDirectory: false)
    }

    // MARK: Lifecycle

    private var listenerRetries = 0
    /// Steady reclaim cadence once backoff has ramped up. We never *give up*:
    /// a stale instance (e.g. a leftover build from another window/worktree)
    /// can own the socket for a long time, and the moment it dies the surviving
    /// instance must take over so the user's live window actually serves MCP.
    /// Previously we stopped after a handful of tries, so a survivor never
    /// reclaimed and `openusdz mcp` kept relaying to a zombie with no document.
    private let reclaimIntervalSeconds = 2.0
    /// False once `stop()` runs, so a scheduled retry can't rebind after teardown.
    private var wantsListening = false

    func start() {
        wantsListening = true
        // Restore a reference image set before this window existed (an agent- or
        // CLI-driven launch persisted it to the hand-off file).
        if let image = ReferenceImage.read(from: Self.referenceURL()) {
            referenceModel.set(path: image.path, caption: image.caption)
        }
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
    /// authority, and our bind will simply fail and be retried.
    private func cleanupStaleSocket(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        let recordPID = (try? Data(contentsOf: Self.endpointURL()))
            .flatMap { try? JSONDecoder().decode(EndpointRecord.self, from: $0) }
            .map(\.pid)
        if Self.isSocketReclaimable(recordPID: recordPID, selfPID: selfPID,
                                    isAlive: { kill(pid_t($0), 0) == 0 || errno == EPERM }) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Pure ownership decision: may we unlink the existing socket and claim it?
    /// Reclaimable when there is no usable endpoint record, the record is our
    /// own leftover, or the recorded owner pid is no longer alive. A *different,
    /// live* owner is never reclaimed — it stays the authority. Mirrors the
    /// liveness test in the CLI's `RelayPump.liveEndpoint`.
    static func isSocketReclaimable(recordPID: Int?, selfPID: Int,
                                    isAlive: (Int) -> Bool) -> Bool {
        guard let recordPID else { return true }   // no/garbage record → stale
        if recordPID == selfPID { return true }    // our own prior socket
        return !isAlive(recordPID)                 // dead owner → reclaim
    }

    /// Retry binding at a steady cadence for the app's lifetime (never giving
    /// up): a transient failure recovers, and — crucially — when a stale owner
    /// finally dies, `cleanupStaleSocket` unlinks its socket and the next tick
    /// binds. The `wantsListening`/`server == nil` guards keep the timer a no-op
    /// once we are serving or have been stopped.
    private func restartListener() {
        server?.stop()
        server = nil
        listenerRetries += 1
        // Ramp 0.5s, 1.0s, 1.5s … up to the steady reclaim cadence, then hold.
        let delay = min(Double(listenerRetries) * 0.5, reclaimIntervalSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsListening, self.server == nil else { return }
            self.start()
        }
    }

    func stop() {
        wantsListening = false
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
    ///
    /// A host is created **even when no document is open** (`document == nil`),
    /// seeded from an empty stage. Otherwise the relay had nothing to answer
    /// with: `initialize`/`tools/list` — which need no document — failed, and
    /// `handleRpc` returned an empty line that the pump read as a dropped
    /// connection, so `openusdz mcp` reported "Failed to connect" whenever the
    /// app was open on an empty window. Edits made against a document-less host
    /// simply don't mirror anywhere until a document opens (then we rebind).
    func bindDocument(_ document: EditorDocument?) {
        boundDocument = document
        makeHost(seededFrom: document?.snapshot)
    }

    /// Ensure a host exists before answering a request, so a relay call that
    /// races ahead of `bindDocument` still gets a real response rather than a
    /// silent empty line. No-op once a host is present.
    private func ensureHost() {
        guard hostServer == nil || hostSession == nil else { return }
        makeHost(seededFrom: boundDocument?.snapshot)
    }

    /// (Re)create the hosted `AgentMCPServer` on a fresh session seeded from
    /// `snapshot` (an empty stage when nil).
    private func makeHost(seededFrom snapshot: StageSnapshot?) {
        let session = EditSession(snapshot: snapshot ?? StageSnapshot(), strictness: .warn)
        let hostPID = Int(ProcessInfo.processInfo.processIdentifier)
        let sink = HostActivitySink(pid: hostPID) { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        // Mirror the agent's reference image into the panel model, and persist
        // the hand-off record so a relaunch (or a window opened later) restores
        // it. Fired on the tool thread; hop to the main actor for UI state.
        session.onReferenceImageChange = { [weak self] image in
            Task { @MainActor in self?.applyReference(image) }
        }
        hostSession = session
        hostServer = AgentMCPServer.make(
            session: session,
            configuration: AgentMCPServer.Configuration(eventSink: sink))
    }

    /// Fold a reference-image change into the panel model and the hand-off file.
    func applyReference(_ image: ReferenceImage?) {
        referenceModel.set(path: image?.path, caption: image?.caption)
        let url = Self.referenceURL()
        if let image { try? image.write(to: url) }
        else { ReferenceImage.remove(at: url) }
    }

    /// Run one relayed JSON-RPC request against the hosted server, mirror the
    /// resulting stage into the live document, and reply on the same socket.
    private func handleRpc(_ frame: RpcRequestFrame, on fd: Int32) {
        ensureHost()   // lazily host a scratch session if nothing is bound yet
        guard let hostServer, let session = hostSession else {
            // Unreachable after ensureHost, but never answer with an empty line:
            // the pump treats empty as a dropped connection (prints nothing), so
            // the JSON-RPC handshake stalls and the client reports a connection
            // failure with no diagnostic. Send a real JSON-RPC error instead
            // (empty only for notifications, which owe no response).
            send(RpcResponseFrame(id: frame.id, line: Self.jsonrpcError(
                for: frame.line, message: "editor host unavailable")), on: fd)
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

    /// A JSON-RPC error `line` addressed to the request's own id, or an empty
    /// line when the request is a notification (no id — owes no response). Keeps
    /// a failed relay call from surfacing as a silent hang.
    static func jsonrpcError(for requestLine: String, code: Int = -32001,
                             message: String) -> String {
        var idFragment = "null"
        if let data = requestLine.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["id"] {
            if let string = id as? String { idFragment = "\"\(string)\"" }
            else if let number = id as? NSNumber { idFragment = "\(number)" }
        }
        guard idFragment != "null" else { return "" }   // notification: no reply
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"jsonrpc\":\"2.0\",\"id\":\(idFragment),\"error\":{\"code\":\(code),\"message\":\"\(escaped)\"}}"
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
