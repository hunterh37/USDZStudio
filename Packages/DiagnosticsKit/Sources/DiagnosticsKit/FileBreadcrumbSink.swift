import Foundation

/// JSON Lines appender — a direct port of `EditingKit.FileCommandJournal`'s
/// proven mechanics: NSLock, seek-to-end, newline-delimited records, one
/// `synchronize()` (fsync) per batch, torn-final-line tolerated on read.
public final class FileBreadcrumbSink: BreadcrumbSink, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder

    /// Opens (creating if needed) a log file at `url`. The parent directory
    /// must already exist — `SessionLogStore` owns directory layout.
    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
    }

    public func write(_ crumbs: [Breadcrumb]) throws {
        guard !crumbs.isEmpty else { return }
        // Encode outside the lock; only the file append is serialized.
        var payload = Data()
        for crumb in crumbs {
            payload.append(try encoder.encode(crumb))
            payload.append(0x0A) // newline
        }
        lock.lock(); defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize() // one fsync per batch: the flush survives a kill.
    }

    /// Reads a session log back. A trailing partial line (crash mid-append) is
    /// discarded; undecodable complete lines are skipped rather than failing
    /// the whole read — a diagnostics reader must be tolerant of newer schemas.
    public static func read(url: URL) throws -> [Breadcrumb] {
        let raw = try Data(contentsOf: url)
        guard !raw.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let hasTrailingNewline = raw.last == 0x0A
        let lines = raw.split(separator: 0x0A, omittingEmptySubsequences: true)
        var crumbs: [Breadcrumb] = []
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 && !hasTrailingNewline { break } // torn final record
            if let crumb = try? decoder.decode(Breadcrumb.self, from: Data(line)) {
                crumbs.append(crumb)
            }
        }
        return crumbs
    }
}
