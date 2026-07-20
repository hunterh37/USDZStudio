import Foundation
import Network

/// Pure frame codec for the CLI↔editor relay (specs/agent-live-editing.md).
///
/// When the editor app is running it hosts the MCP server against its open
/// document, and `openusdz mcp` becomes a thin pump: each stdin JSON-RPC line
/// is wrapped in an `rpc_request` frame, sent to the app over the localhost
/// socket, and the correlated `rpc_response` frame's line is written to stdout.
/// The app decodes/encodes the mirror shape (it can't import this target).
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

    /// Decode one NDJSON line as an `rpc_response`; nil if it's any other frame
    /// (e.g. a stray activity event) or malformed.
    static func decodeResponse(_ line: Data) -> Response? {
        guard let r = try? JSONDecoder().decode(Response.self, from: line),
              r.type == "rpc_response" else { return nil }
        return r
    }

    /// Split a rolling buffer into complete NDJSON lines, returning the lines
    /// and the unconsumed remainder. Pure, so it's unit-tested directly.
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
}

// coverage:disable — composition-root network IO: opens a live localhost
// connection to the running editor and pumps stdin↔socket↔stdout. The frame
// codec (`RelayCodec`) is unit-tested; exercising NWConnection needs a live
// listener, covered by the end-to-end verification recipe.

/// Resolves a live editor endpoint and pumps JSON-RPC to it.
final class RelayPump: @unchecked Sendable {
    private let endpointURL: URL
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "openusdz.relay")
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Int: CheckedContinuation<String, Never>] = [:]

    private init(endpointURL: URL, connection: NWConnection) {
        self.endpointURL = endpointURL
        self.connection = connection
    }

    /// A live, reachable editor endpoint, or nil (caller falls back to the
    /// in-process file-backed server).
    static func liveEndpoint(at url: URL) -> MCPEndpointInfo? {
        guard let info = SocketEventSink.readEndpoint(from: url),
              kill(pid_t(info.pid), 0) == 0 || errno == EPERM,
              info.port > 0
        else { return nil }
        return info
    }

    static func make(endpointURL: URL) -> RelayPump? {
        guard let info = liveEndpoint(at: endpointURL),
              let port = NWEndpoint.Port(rawValue: UInt16(info.port)) else { return nil }
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        return RelayPump(endpointURL: endpointURL, connection: conn)
    }

    /// Pump stdin → app → stdout until stdin closes or the connection drops.
    func run() async -> Int32 {
        connection.start(queue: queue)
        receiveLoop()
        var nextID = 0
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            nextID += 1
            let id = nextID
            connection.send(content: RelayCodec.encodeRequest(id: id, line: line),
                            completion: .contentProcessed { _ in })
            let response = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                lock.lock(); waiters[id] = c; lock.unlock()
            }
            if !response.isEmpty {
                print(response)
                fflush(stdout)
            }
        }
        connection.cancel()
        return 0
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                let (lines, rest) = RelayCodec.drainLines(self.buffer)
                self.buffer = rest
                var resumed: [(CheckedContinuation<String, Never>, String)] = []
                for line in lines {
                    if let resp = RelayCodec.decodeResponse(line), let c = self.waiters.removeValue(forKey: resp.id) {
                        resumed.append((c, resp.line))
                    }
                }
                self.lock.unlock()
                for (c, line) in resumed { c.resume(returning: line) }
            }
            if isComplete || error != nil {
                self.failAllWaiters()
                return
            }
            self.receiveLoop()
        }
    }

    private func failAllWaiters() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for (_, c) in pending { c.resume(returning: "") }
    }
}
// coverage:enable
