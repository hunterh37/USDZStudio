import Foundation

/// Destination for flushed breadcrumbs. The contract is tiny on purpose:
/// append a batch durably. Batching is owned by `BreadcrumbLogger`; a sink
/// never sees individual crumbs, so one flush is one write + one fsync.
public protocol BreadcrumbSink: AnyObject, Sendable {
    /// Appends `crumbs` in order. On return the batch must be as durable as
    /// the sink can make it (file sinks fsync). Throws on I/O failure.
    func write(_ crumbs: [Breadcrumb]) throws
}

/// RAM-only sink for tests and headless tools. Same contract, no I/O.
public final class InMemoryBreadcrumbSink: BreadcrumbSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Breadcrumb] = []

    public init() {}

    public func write(_ crumbs: [Breadcrumb]) throws {
        lock.lock(); defer { lock.unlock() }
        stored.append(contentsOf: crumbs)
    }

    /// Everything written so far, in order.
    public var crumbs: [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
