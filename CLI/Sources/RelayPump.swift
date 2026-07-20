import Foundation
import Network

/// Pure frame codec + decision logic for the CLI↔editor relay
/// (specs/agent-live-editing.md).
///
/// When the editor app is running it hosts the MCP server against its open
/// document, and `openusdz mcp` becomes a thin pump: each stdin JSON-RPC line
/// is wrapped in an `rpc_request` frame, sent to the app over the localhost
/// socket, and the correlated `rpc_response` frame's line is written to stdout.
enum RelayCodec {
    struct Request: Codable, Equatable {
        var v = 1
        var type = "rpc_request"
        var id: Int
        var line: String
    }

    struct Response: Decodable, Equatable {
        var type: String
        var id: Int
        var line: String
    }

    /// One newline-terminated `rpc_request` NDJSON frame.
    static func encodeRequest(id: Int, line: String) -> Data {
        var data = (try? JSONEncoder().encode(Request(id: id, line: line))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Decode one NDJSON line as an `rpc_response`; nil for any other frame.
    static func decodeResponse(_ line: Data) -> Response? {
        guard let r = try? JSONDecoder().decode(Response.self, from: line),
              r.type == "rpc_response" else { return nil }
        return r
    }

    /// Split a rolling buffer into complete NDJSON lines + unconsumed remainder.
    static func drainLines(_ buffer: Data) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var rest = buffer
        while let nl = rest.firstIndex(of: 0x0A) {
            let line = rest[rest.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            rest = Data(rest[rest.index(after: nl)...])
        }
        return (lines, rest)
    }

    /// The JSON-RPC `id` of a request line, as a JSON fragment string ("4",
    /// "\"abc\"", or "null" for a notification / unparseable). Used to address a
    /// synthesized error back to the right call.
    static func jsonrpcIDFragment(_ line: String) -> String {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"]
        else { return "null" }
        if let s = id as? String { return "\"\(s)\"" }
        if let n = id as? NSNumber { return "\(n)" }
        return "null"
    }

    /// Whether a request line is a notification (no `id`) — no response is owed.
    static func isNotification(_ line: String) -> Bool {
        jsonrpcIDFragment(line) == "null"
    }

    /// A spec-shaped JSON-RPC error response addressed to `idFragment`, so a
    /// dropped editor surfaces as a correctable error, never a hang.
    static func errorResponse(idFragment: String, code: Int, message: String) -> String {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"jsonrpc\":\"2.0\",\"id\":\(idFragment),\"error\":{\"code\":\(code),\"message\":\"\(escaped)\"}}"
    }

    /// Poll `resolve` up to `attempts` times (caller sleeps between via `tick`),
    /// returning the first live endpoint — the bounded wait that absorbs the
    /// app-launch race. Pure: inject `resolve`/`tick` in tests.
    static func awaitEndpoint(
        attempts: Int,
        resolve: () -> MCPEndpointInfo?,
        tick: () -> Void
    ) -> MCPEndpointInfo? {
        var remaining = max(1, attempts)
        while remaining > 0 {
            if let info = resolve() { return info }
            remaining -= 1
            if remaining > 0 { tick() }
        }
        return nil
    }
}

// coverage:disable — composition-root network IO: opens/reopens a live
// localhost connection to the running editor and pumps stdin↔socket↔stdout.
// The frame codec and decision logic (`RelayCodec`) are unit-tested; exercising
// NWConnection needs a live listener, covered by the end-to-end recipe.

/// Result of awaiting one relayed request.
private enum RelayReply {
    case ok(String)
    case failed
}

/// Resilient pump: bounded wait for the editor, persistent connection with
/// reconnect-on-drop, per-request response timeout, and endpoint
/// re-resolution when reconnecting (survives an app restart on a new port).
final class RelayPump: @unchecked Sendable {
    private let endpointURL: URL
    private let queue = DispatchQueue(label: "openusdz.relay")
    private let lock = NSLock()

    private var connection: NWConnection?
    private var buffer = Data()
    private var waiters: [Int: CheckedContinuation<RelayReply, Never>] = [:]
    private var nextID = 0

    // Tunables (conservative, enterprise-safe defaults).
    private let connectAttempts = 25          // ~2.5s bounded wait for the app
    private let connectTickMS: UInt64 = 100
    private let requestTimeoutMS: UInt64 = 15_000
    private let reconnectTriesPerRequest = 2

    private init(endpointURL: URL) {
        self.endpointURL = endpointURL
    }

    /// A live, reachable editor endpoint right now (nil otherwise).
    static func liveEndpoint(at url: URL) -> MCPEndpointInfo? {
        guard let info = SocketEventSink.readEndpoint(from: url),
              info.port > 0,
              kill(pid_t(info.pid), 0) == 0 || errno == EPERM
        else { return nil }
        return info
    }

    /// Decide up front whether an editor is reachable, waiting briefly so a
    /// reconnect issued *during* app launch still finds the endpoint. Returns a
    /// pump only when the editor is present; otherwise the caller runs the
    /// in-process file-backed server.
    static func make(endpointURL: URL) -> RelayPump? {
        let pump = RelayPump(endpointURL: endpointURL)
        let found = RelayCodec.awaitEndpoint(
            attempts: pump.connectAttempts,
            resolve: { liveEndpoint(at: endpointURL) },
            tick: { usleep(useconds_t(pump.connectTickMS * 1000)) })
        return found != nil ? pump : nil
    }

    /// Pump stdin → editor → stdout until stdin closes. Each request reconnects
    /// on demand; a lost/hung editor yields a JSON-RPC error, never a hang.
    func run() async -> Int32 {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            let reply = await relayOne(line)
            switch reply {
            case .ok(let response):
                if !response.isEmpty { print(response); fflush(stdout) }
            case .failed:
                // Notifications owe no response; a real call gets a clean error.
                if !RelayCodec.isNotification(line) {
                    print(RelayCodec.errorResponse(
                        idFragment: RelayCodec.jsonrpcIDFragment(line),
                        code: -32001,
                        message: "editor connection lost; reopen the document or reconnect"))
                    fflush(stdout)
                }
            }
        }
        teardown()
        return 0
    }

    private func relayOne(_ line: String) async -> RelayReply {
        for attempt in 0...reconnectTriesPerRequest {
            guard ensureConnected() else {
                // Editor went away entirely — brief wait for it to return.
                if attempt < reconnectTriesPerRequest { usleep(200_000); continue }
                return .failed
            }
            let id = allocID()
            send(RelayCodec.encodeRequest(id: id, line: line))
            let reply = await awaitReply(id: id)
            if case .ok = reply { return reply }
            dropConnection()   // timeout or socket error → reconnect & retry
        }
        return .failed
    }

    // MARK: Connection management

    private func ensureConnected() -> Bool {
        lock.lock()
        if connection != nil { lock.unlock(); return true }
        lock.unlock()
        guard let info = Self.liveEndpoint(at: endpointURL),
              let port = NWEndpoint.Port(rawValue: UInt16(info.port)) else { return false }
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.dropConnection()
            default: break
            }
        }
        conn.start(queue: queue)
        lock.lock(); connection = conn; buffer = Data(); lock.unlock()
        receiveLoop(conn)
        return true
    }

    private func allocID() -> Int {
        lock.lock(); nextID += 1; let id = nextID; lock.unlock(); return id
    }

    private func send(_ data: Data) {
        lock.lock(); let conn = connection; lock.unlock()
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func awaitReply(id: Int) async -> RelayReply {
        await withCheckedContinuation { (c: CheckedContinuation<RelayReply, Never>) in
            lock.lock(); waiters[id] = c; lock.unlock()
            // Timeout guard: resume `.failed` if the editor never answers.
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(requestTimeoutMS))) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let waiter = self.waiters.removeValue(forKey: id)
                self.lock.unlock()
                waiter?.resume(returning: .failed)
            }
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                let (lines, rest) = RelayCodec.drainLines(self.buffer)
                self.buffer = rest
                var resumed: [(CheckedContinuation<RelayReply, Never>, String)] = []
                for line in lines {
                    if let resp = RelayCodec.decodeResponse(line),
                       let c = self.waiters.removeValue(forKey: resp.id) {
                        resumed.append((c, resp.line))
                    }
                }
                self.lock.unlock()
                for (c, line) in resumed { c.resume(returning: .ok(line)) }
            }
            if isComplete || error != nil { self.dropConnection(); return }
            self.receiveLoop(conn)
        }
    }

    private func dropConnection() {
        lock.lock()
        connection?.cancel()
        connection = nil
        let pending = waiters
        waiters.removeAll()
        buffer = Data()
        lock.unlock()
        for (_, c) in pending { c.resume(returning: .failed) }
    }

    private func teardown() { dropConnection() }
}
// coverage:enable
