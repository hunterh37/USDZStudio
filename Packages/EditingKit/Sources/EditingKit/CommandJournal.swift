import Foundation
import USDCore

/// One line in the write-ahead log. The journal is an append-only sequence of
/// these, one JSON object per line (JSON Lines) — so a crash mid-write loses at
/// most the final, partial record and every complete record before it replays.
public enum JournalRecord: Codable, Equatable, Sendable {
    /// Marks the base document the following records replay against. Written
    /// when a journal is opened for a document and again after every save/clear
    /// (which flattens history), so recovery always starts from a known file.
    case checkpoint(sourceURL: URL?)
    /// A command committed via `CommandStack.run`. `forward` is the exact list
    /// of mutations it applied; `inverse` reverses them (apply in reverse order).
    case command(label: String, forward: [StageMutation], inverse: [StageMutation])
    /// The top undo-stack command was undone.
    case undo
    /// The top redo-stack command was redone.
    case redo
}

/// Append-only write-ahead log of `JournalRecord`s.
///
/// The contract is deliberately tiny: append durably, read everything back,
/// truncate. `CommandStack` writes one record per stack operation; recovery
/// reads them all and replays. Implementations must make `append` durable
/// enough that a process kill after it returns cannot lose the record.
public protocol CommandJournal: AnyObject, Sendable {
    /// Durably appends one record. Throws if the record can't be written.
    func append(_ record: JournalRecord) throws
    /// Every record appended so far, in order.
    func readAll() throws -> [JournalRecord]
    /// Drops all records — called after a save/clear flattens history. A fresh
    /// checkpoint should be appended immediately afterwards by the caller.
    func reset() throws
}

/// A file-backed WAL. One JSON object per line, appended with an `fsync` so a
/// completed `append` survives a power loss or `SIGKILL`. Reads tolerate a
/// torn final line (a crash mid-append) by discarding only that line.
public final class FileCommandJournal: CommandJournal, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Opens (creating if needed) a WAL at `url`. The parent directory must
    /// already exist — `SessionStore` owns directory layout.
    public init(url: URL) throws {
        self.url = url
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public func append(_ record: JournalRecord) throws {
        let data = try encoder.encode(record)
        try lock.withLock {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A])) // newline
            try handle.synchronize() // fsync: the record now survives a kill.
        }
    }

    public func readAll() throws -> [JournalRecord] {
        let raw = try lock.withLock { try Data(contentsOf: url) }
        guard !raw.isEmpty else { return [] }
        var records: [JournalRecord] = []
        // Split on newlines; a trailing partial line (no newline) is a torn
        // write from a crash and is skipped.
        let hasTrailingNewline = raw.last == 0x0A
        let lines = raw.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (i, line) in lines.enumerated() {
            let isLast = i == lines.count - 1
            if isLast && !hasTrailingNewline {
                break // torn final record — discard.
            }
            records.append(try decoder.decode(JournalRecord.self, from: Data(line)))
        }
        return records
    }

    public func reset() throws {
        try lock.withLock {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.synchronize()
        }
    }
}

/// A RAM-only journal for tests and headless replay. Same contract, no fsync.
public final class InMemoryCommandJournal: CommandJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [JournalRecord] = []

    public init(records: [JournalRecord] = []) { self.records = records }

    public func append(_ record: JournalRecord) throws {
        lock.withLock { records.append(record) }
    }
    public func readAll() throws -> [JournalRecord] {
        lock.withLock { records }
    }
    public func reset() throws {
        lock.withLock { records.removeAll() }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
