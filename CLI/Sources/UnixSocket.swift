import Foundation

/// Pure helpers for the AF_UNIX transport used by the agent-live relay
/// (specs/agent-live-editing.md). The same-machine transport is a UNIX-domain
/// socket rather than loopback TCP: no port, and no macOS Local Network privacy
/// prompt (which intermittently left a fresh app with no listening socket at
/// all). Only the transport changes — the NDJSON frame contract is unchanged.
enum UnixSocketPath {
    /// `sockaddr_un.sun_path` capacity on Darwin (104 bytes). A path whose UTF-8
    /// length is `>= maxLength` cannot be bound/connected and must be rejected up
    /// front rather than silently truncated into a wrong path.
    static let maxLength = 104

    /// Whether `path` fits (with its NUL terminator) in `sun_path`.
    static func fits(_ path: String) -> Bool {
        let count = path.utf8.count
        return count > 0 && count < maxLength
    }
}

// coverage:disable — POSIX AF_UNIX socket IO: connects to the running editor's
// UNIX-domain socket and pumps bytes. NWConnection does not cleanly support
// AF_UNIX on the deployment target, so this drops to socket()/connect() +
// DispatchSource. The pure seams (UnixSocketPath, frame codec, endpoint decode)
// are unit-tested; exercising a live socket is covered by the end-to-end recipe.

/// A connected AF_UNIX stream client. Reads are delivered on `queue` as they
/// arrive; `send` writes the full buffer (handling short writes and EINTR).
/// Every method is a graceful no-op once the socket has been closed.
final class UnixSocketClient: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var closed = false
    private let lock = NSLock()

    private init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// Open and connect a client socket to `path`. Returns nil when the path is
    /// unusable or the peer isn't accepting (no editor / stale socket file).
    static func connect(path: String, queue: DispatchQueue) -> UnixSocketClient? {
        guard UnixSocketPath.fits(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withSockaddrUn(path: path) { addrPtr, len in
            Darwin.connect(fd, addrPtr, len)
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        return UnixSocketClient(fd: fd, queue: queue)
    }

    /// Begin delivering inbound bytes. `onData` fires on `queue`; `onClose` fires
    /// once on EOF or error.
    func startReceiving(onData: @escaping @Sendable (Data) -> Void,
                        onClose: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = chunk.withUnsafeMutableBytes { read(self.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onData(Data(chunk[0..<n]))
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                self.close()
                onClose()
            }
        }
        lock.lock(); readSource = source; lock.unlock()
        source.resume()
    }

    /// Write the entire buffer, looping over short writes. Errors close the
    /// socket (the pump then reconnects on its next request).
    func send(_ data: Data) {
        lock.lock(); let live = !closed; lock.unlock()
        guard live else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    close()
                    return
                }
            }
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        Darwin.close(fd)
    }
}

/// Pack `path` into a `sockaddr_un` and invoke `body` with a `sockaddr` pointer
/// and its length. Shared by client connect and (app-side) listener bind.
func withSockaddrUn<R>(path: String,
                       _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: UInt8.self, capacity: UnixSocketPath.maxLength) { dst in
            for (index, byte) in bytes.enumerated() where index < UnixSocketPath.maxLength - 1 {
                dst[index] = byte
            }
            dst[min(bytes.count, UnixSocketPath.maxLength - 1)] = 0
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
    }
}
// coverage:enable
