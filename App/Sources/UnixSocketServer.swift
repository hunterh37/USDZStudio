import Foundation

/// App-side AF_UNIX listener for the agent-live relay (specs/agent-live-editing.md).
///
/// The same-machine transport is a UNIX-domain socket rather than loopback TCP.
/// On recent macOS, a fresh app bound with `NWListener(using: .tcp)` sometimes
/// never reached `.ready` (the Local Network privacy gate), so no endpoint was
/// ever published and live editing silently broke. A UNIX socket needs no port
/// and triggers no TCC prompt. `NWListener`/`NWConnection` don't cleanly support
/// AF_UNIX on the deployment target, so this drops to POSIX
/// socket()/bind()/listen()/accept() + DispatchSource. The NDJSON frame contract
/// is unchanged — only the transport differs.
///
/// Lives in the (un-coverage-gated) app target because it owns app-lifecycle
/// socket IO. The reducer and frame decode in `MCPActivityListener` remain
/// unit-testable with synthetic events.
final class UnixSocketServer: @unchecked Sendable {
    /// One complete NDJSON line arrived on a connection (identified by its fd).
    typealias LineHandler = @Sendable (_ line: Data, _ connection: Int32) -> Void

    private let queue = DispatchQueue(label: "openusdz.mcp-listener", qos: .utility)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connSources: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]

    private var onLine: LineHandler?
    private var onDisconnect: (@Sendable (Int32) -> Void)?

    /// Bind + listen on `path` and begin accepting. Returns false on any failure
    /// (bad path, address in use by a live owner, bind/listen error) — the caller
    /// retries with backoff. Does not unlink `path`; stale-socket cleanup is the
    /// caller's decision (it knows pid ownership).
    func start(path: String,
               onLine: @escaping LineHandler,
               onDisconnect: @escaping @Sendable (Int32) -> Void) -> Bool {
        guard UnixSocketPathA.fits(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withSockaddrUnA(path: path) { addrPtr, len in bind(fd, addrPtr, len) }
        guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); return false }

        lock.lock()
        listenFD = fd
        self.onLine = onLine
        self.onDisconnect = onDisconnect
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        lock.lock(); listenSource = source; lock.unlock()
        source.resume()
        return true
    }

    private func acceptPending() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readConnection(client) }
        source.setCancelHandler { Darwin.close(client) }
        lock.lock()
        connSources[client] = source
        buffers[client] = Data()
        lock.unlock()
        source.resume()
    }

    private func readConnection(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            lock.lock()
            var buffer = buffers[fd] ?? Data()
            buffer.append(contentsOf: chunk[0..<n])
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { lines.append(line) }
            }
            buffers[fd] = buffer
            let handler = onLine
            lock.unlock()
            for line in lines { handler?(line, fd) }
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            closeConnection(fd)
        }
    }

    /// Write a full NDJSON frame back to one connection.
    func send(_ data: Data, to fd: Int32) {
        queue.async {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n > 0 { offset += n }
                    else if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    else { return }
                }
            }
        }
    }

    private func closeConnection(_ fd: Int32) {
        lock.lock()
        let source = connSources.removeValue(forKey: fd)
        buffers[fd] = nil
        let disconnect = onDisconnect
        lock.unlock()
        source?.cancel()   // cancel handler closes the fd
        disconnect?(fd)
    }

    /// Tear down the listener and every open connection.
    func stop() {
        lock.lock()
        let ls = listenSource
        let lfd = listenFD
        let sources = connSources
        listenSource = nil
        listenFD = -1
        connSources.removeAll()
        buffers.removeAll()
        lock.unlock()
        for (_, s) in sources { s.cancel() }
        ls?.cancel()
        if lfd >= 0 { Darwin.close(lfd) }
    }
}

/// `sun_path` capacity on Darwin; a path must be shorter (with its NUL).
enum UnixSocketPathA {
    static let maxLength = 104
    static func fits(_ path: String) -> Bool {
        let count = path.utf8.count
        return count > 0 && count < maxLength
    }
}

/// Pack `path` into a `sockaddr_un` and invoke `body` with a `sockaddr` pointer.
func withSockaddrUnA<R>(path: String,
                        _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: UInt8.self, capacity: UnixSocketPathA.maxLength) { dst in
            for (index, byte) in bytes.enumerated() where index < UnixSocketPathA.maxLength - 1 {
                dst[index] = byte
            }
            dst[min(bytes.count, UnixSocketPathA.maxLength - 1)] = 0
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
    }
}
