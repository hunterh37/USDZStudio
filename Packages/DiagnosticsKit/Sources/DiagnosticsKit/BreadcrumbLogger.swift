import Foundation
import os

/// App-facing breadcrumb API. `log` must be cheap and non-throwing so call
/// sites (command commits, UI actions, MCP events) can sprinkle crumbs freely.
public protocol BreadcrumbLogging: AnyObject, Sendable {
    /// Records one breadcrumb. Never throws, never blocks meaningfully.
    func log(_ category: BreadcrumbCategory, level: BreadcrumbLevel,
             _ message: String, metadata: [String: String])
    /// Drains any buffered crumbs to the sink now.
    func flush()
}

extension BreadcrumbLogging {
    /// Convenience: `.info` level, empty metadata by default.
    public func log(_ category: BreadcrumbCategory, level: BreadcrumbLevel = .info,
                    _ message: String, metadata: [String: String] = [:]) {
        log(category, level: level, message, metadata: metadata)
    }
}

/// Buffered breadcrumb logger with an explicit durability policy.
///
/// Breadcrumbs are diagnostics, not user data, so unlike `EditingKit`'s WAL we
/// do NOT fsync every record. Instead the buffer is flushed (one batched write
/// + one fsync) when any of these fire:
///   1. a crumb at or above `flushAtOrAbove` arrives (default `.warning` —
///      trouble usually precedes a crash, so trouble is durable immediately);
///   2. the buffer reaches `maxBuffered` crumbs;
///   3. the periodic `flushInterval` tick (default 2 s);
///   4. `flush()` / `shutdown()` is called.
/// Worst case a hard kill loses ≤ `flushInterval` of `.debug`/`.info` crumbs.
///
/// Sink failures are swallowed: a diagnostics subsystem must never take the
/// app down or interrupt an edit because a log write failed.
///
/// Locking over an actor deliberately: call sites need a synchronous,
/// ordering-preserving `log`, and `applicationWillTerminate` needs a
/// synchronous final drain — matching the NSLock pattern used across the repo.
public final class BreadcrumbLogger: BreadcrumbLogging, @unchecked Sendable {
    private let sink: any BreadcrumbSink
    private let flushAtOrAbove: BreadcrumbLevel
    private let maxBuffered: Int
    private let mirror: os.Logger?
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var buffer: [Breadcrumb] = []
    private var nextSeq: UInt64 = 0
    private var isShutdown = false
    private var intervalTask: Task<Void, Never>?

    /// - Parameters:
    ///   - flushInterval: periodic background flush cadence; `nil` disables the
    ///     timer (tests, short-lived CLI runs — rely on the other triggers).
    ///   - mirrorToOSLog: also emit each crumb to the unified log
    ///     (`subsystem "com.usdzstudio"`) so crumbs show up in Console.app.
    ///   - now: injectable clock for deterministic tests.
    public init(sink: any BreadcrumbSink,
                flushAtOrAbove: BreadcrumbLevel = .warning,
                maxBuffered: Int = 64,
                flushInterval: Duration? = .seconds(2),
                mirrorToOSLog: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.flushAtOrAbove = flushAtOrAbove
        self.maxBuffered = max(1, maxBuffered)
        self.mirror = mirrorToOSLog
            ? os.Logger(subsystem: "com.usdzstudio", category: "breadcrumbs") : nil
        self.now = now
        if let interval = flushInterval {
            // Weak self: the timer must not keep a discarded logger alive.
            intervalTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    self?.flush()
                }
            }
        }
    }

    deinit { intervalTask?.cancel() }

    public func log(_ category: BreadcrumbCategory, level: BreadcrumbLevel,
                    _ message: String, metadata: [String: String]) {
        lock.lock()
        guard !isShutdown else { lock.unlock(); return }
        let crumb = Breadcrumb(seq: nextSeq, timestamp: now(), category: category,
                               level: level, message: message, metadata: metadata)
        nextSeq += 1
        buffer.append(crumb)
        let shouldFlush = level >= flushAtOrAbove || buffer.count >= maxBuffered
        lock.unlock()

        if let mirror {
            mirror.log(level: Self.osLogType(for: level),
                       "[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        }
        if shouldFlush { flush() }
    }

    public func flush() {
        lock.lock()
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        // Swallow sink failures (see type doc); the batch is dropped rather
        // than retried so a persistently failing disk can't grow memory.
        try? sink.write(batch)
    }

    /// Final synchronous drain for `applicationWillTerminate`: stops the timer,
    /// flushes, and ignores all subsequent `log` calls.
    public func shutdown() {
        lock.lock()
        isShutdown = true
        lock.unlock()
        intervalTask?.cancel()
        flush()
    }

    static func osLogType(for level: BreadcrumbLevel) -> OSLogType {
        switch level {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        case .fault: .fault
        }
    }
}
