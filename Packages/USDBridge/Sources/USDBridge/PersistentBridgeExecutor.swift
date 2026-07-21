import Foundation
import USDCore

/// A `BridgeExecutor` that keeps **one** Python interpreter resident and serves
/// every file open over its stdin/stdout, instead of spawning a fresh
/// interpreter (and re-paying `import pxr`, several hundred ms) per open.
///
/// It speaks the framed protocol in `Resources/Python/bridge_server.py`, which
/// reuses `stage_snapshot.build_snapshot` — so the JSON it returns is identical
/// to what the one-shot `ProcessBridgeExecutor` returns and `StageSnapshotDecoder`
/// decodes both unchanged. Everything downstream of `snapshotJSON` is untouched.
///
/// **Reliability floor:** a warm worker can die (a crash in usd-core, a closed
/// pipe). Any *transport* failure tears the worker down and serves that one open
/// through a one-shot `ProcessBridgeExecutor`, so this path is never worse than
/// the subprocess baseline — only faster on the common warm case. A *clean*
/// error the worker reports (a malformed file it refused to open) propagates as
/// usual, without a pointless respawn.
///
/// An `actor` because a single worker has a single request/response channel:
/// concurrent opens must be serialized, which actor isolation gives for free.
public actor PersistentBridgeExecutor: BridgeExecutor {

    public let pythonPath: String
    public let serverScriptPath: String
    private let fallback: ProcessBridgeExecutor
    private var worker: Worker?

    public init(pythonPath: String, serverScriptPath: String) {
        self.pythonPath = pythonPath
        self.serverScriptPath = serverScriptPath
        // The one-shot fallback runs the snapshot script that ships beside the
        // server, through the same interpreter.
        let snapshotScript = URL(fileURLWithPath: serverScriptPath)
            .deletingLastPathComponent()
            .appendingPathComponent("stage_snapshot.py").path
        self.fallback = ProcessBridgeExecutor(pythonPath: pythonPath, scriptPath: snapshotScript)
    }

    /// Builds an executor from the locator, or `nil` when no interpreter exists.
    public init?(locator: PythonRuntimeLocator = PythonRuntimeLocator(), serverScriptPath: String) {
        guard let python = locator.locate() else { return nil }
        self.init(pythonPath: python, serverScriptPath: serverScriptPath)
    }

    // MARK: BridgeExecutor

    public func snapshotJSON(forFileAt url: URL) async throws -> Data {
        do {
            return try request(op: "snapshot", path: url.path)
        } catch is TransportFailure {
            // Warm path broke — never let that fail an open the subprocess would
            // have handled. Drop the dead worker and serve this one one-shot.
            shutdown()
            return try await fallback.snapshotJSON(forFileAt: url)
        }
    }

    public func checkAvailability() async -> BridgeAvailability {
        do {
            _ = try request(op: "ping", path: nil)
            return .available(pythonPath: pythonPath)
        } catch {
            shutdown()
            return await fallback.checkAvailability()
        }
    }

    /// Stops the resident worker (best effort). Safe to call repeatedly; the
    /// next request lazily restarts one.
    public func shutdown() {
        guard let worker else { return }
        self.worker = nil
        worker.terminate()
    }

    // MARK: Request/response

    /// Sends one request and reads its framed reply. Throws `TransportFailure`
    /// for infrastructure problems (dead worker, malformed frame) — the caller's
    /// fallback trigger — and `BridgeError.executionFailed` for a clean `ERR`
    /// the worker reported, which should surface unchanged.
    private func request(op: String, path: String?) throws -> Data {
        let worker = try ensureWorker()
        do {
            try worker.write(Self.encodeRequest(op: op, path: path))
            let header = try worker.readLine()
            guard let frame = Self.parseFrameHeader(header) else {
                throw TransportFailure(detail: "bad frame header: \(header.debugDescription)")
            }
            let payload = try worker.readExactly(frame.length)
            switch frame.status {
            case .ok:
                return payload
            case .err:
                throw BridgeError.executionFailed(
                    pythonTraceback: String(decoding: payload, as: UTF8.self))
            }
        } catch let error as TransportFailure {
            throw error
        } catch let error as BridgeError {
            throw error   // clean application error — do not treat as transport
        } catch {
            throw TransportFailure(detail: error.localizedDescription)
        }
    }

    private func ensureWorker() throws -> Worker {
        if let worker, worker.isRunning { return worker }
        shutdown()
        do {
            let started = try Worker(pythonPath: pythonPath, serverScriptPath: serverScriptPath)
            worker = started
            return started
        } catch {
            throw TransportFailure(detail: "failed to launch worker: \(error.localizedDescription)")
        }
    }

    // MARK: Framing (pure, unit-tested)

    struct TransportFailure: Error { let detail: String }

    enum FrameStatus: String { case ok = "OK", err = "ERR" }

    /// Encodes a request as one line of JSON terminated by `\n`. Uses
    /// `JSONSerialization` so arbitrary paths (spaces, quotes, backslashes) are
    /// escaped correctly rather than hand-built.
    static func encodeRequest(op: String, path: String?) -> Data {
        var object: [String: String] = ["op": op]
        if let path { object["path"] = path }
        // A fixed, tiny object of string→string never fails to serialize.
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"op\":\"\(op)\"}".utf8)
        data.append(0x0A)
        return data
    }

    /// Parses a `"<STATUS> <length>"` header, or `nil` when it is malformed.
    static func parseFrameHeader(_ line: String) -> (status: FrameStatus, length: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count == 2,
              let status = FrameStatus(rawValue: String(parts[0])),
              let length = Int(parts[1]), length >= 0 else { return nil }
        return (status, length)
    }
}

/// The resident child process and its two pipe endpoints. Actor-isolated: only
/// ever touched from inside `PersistentBridgeExecutor`, so its non-`Sendable`
/// members (`Process`, `FileHandle`) never cross a concurrency boundary.
private final class Worker {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle

    var isRunning: Bool { process.isRunning }

    init(pythonPath: String, serverScriptPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [serverScriptPath]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // The server reports errors as framed ERR payloads on stdout; its raw
        // stderr (interpreter banners, tracebacks) is not part of the protocol.
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        // A resident worker can die between our `process.isRunning` check and a
        // write (a crash in usd-core, `exit`, or a shutdown race). Writing to the
        // now-closed read end otherwise delivers SIGPIPE, whose default action
        // kills our *whole* process — not the thrown `EPIPE` the write path
        // expects. F_SETNOSIGPIPE makes the syscall return EPIPE instead, so a
        // dead worker surfaces as a thrown error → TransportFailure → one-shot
        // fallback, exactly as the reliability floor intends.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ data: Data) throws {
        try input.write(contentsOf: data)
    }

    /// Reads one `\n`-terminated line (the frame header, always short).
    func readLine() throws -> String {
        var bytes = [UInt8]()
        while true {
            guard let chunk = try output.read(upToCount: 1), let byte = chunk.first else {
                throw PersistentBridgeExecutor.TransportFailure(detail: "worker closed before reply")
            }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads exactly `count` bytes, looping until the payload is whole.
    func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try output.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw PersistentBridgeExecutor.TransportFailure(detail: "worker closed mid-frame")
            }
            data.append(chunk)
        }
        return data
    }

    func terminate() {
        // Ask the loop to exit cleanly; fall back to a signal if it is wedged.
        if process.isRunning {
            try? input.write(contentsOf: Data(#"{"op":"shutdown"}"#.utf8) + Data([0x0A]))
            try? input.close()
        }
        if process.isRunning { process.terminate() }
    }
}
