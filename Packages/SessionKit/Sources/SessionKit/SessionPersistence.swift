import Foundation
import EditingKit

/// Where the session envelope and per-document write-ahead logs live.
///
/// Injected into ``SessionStore`` so the app writes to Application Support while
/// tests use a temporary directory (or the in-memory backend), mirroring the
/// injectable-`UserDefaults` pattern the camera-bookmark and settings stores use.
public protocol SessionPersistence: Sendable {
    /// Loads the stored envelope. Returns `nil` when none has been written;
    /// throws ``SessionError/corruptState`` when a file exists but can't decode.
    func loadState() throws -> SessionState
    /// Persists the envelope durably (atomically, for the file backend).
    func saveState(_ state: SessionState) throws
    /// Drops all session data (envelope + journals) — a decline or a clean quit.
    func deleteAll() throws
    /// Every WAL record for the document whose journal is at `relativePath`
    /// (empty when the journal is absent).
    func readJournalRecords(relativePath: String) throws -> [JournalRecord]
    /// A journal the caller can keep appending to, at `relativePath`.
    func makeJournal(relativePath: String) throws -> any CommandJournal
}

/// File-backed persistence under a base directory (default: Application Support).
///
/// Layout:
/// ```
/// <base>/Sessions/session.json      # the envelope (atomic temp-write + replace)
/// <base>/Sessions/<relativePath>    # each document's FileCommandJournal WAL
/// ```
public final class FileSessionPersistence: SessionPersistence, @unchecked Sendable {
    /// The `Sessions` directory holding the envelope and journals.
    public let sessionsDirectory: URL
    private let stateURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Creates persistence rooted at `baseDirectory`; the `Sessions` subfolder is
    /// created lazily on first write.
    public init(baseDirectory: URL) {
        self.sessionsDirectory = baseDirectory.appendingPathComponent("Sessions", isDirectory: true)
        self.stateURL = sessionsDirectory.appendingPathComponent("session.json")
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    /// The default location: `~/Library/Application Support/OpenUSDZEditor`.
    public static func applicationSupport(
        appDirectoryName: String = "OpenUSDZEditor"
    ) -> FileSessionPersistence {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return FileSessionPersistence(baseDirectory: base.appendingPathComponent(appDirectoryName, isDirectory: true))
    }

    public func loadState() throws -> SessionState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return SessionState()  // absence → an empty envelope (no documents).
        }
        let data = try Data(contentsOf: stateURL)
        do {
            return try decoder.decode(SessionState.self, from: data)
        } catch {
            throw SessionError.corruptState
        }
    }

    public func saveState(_ state: SessionState) throws {
        try ensureDirectory()
        let data = try encoder.encode(state)
        // Atomic write: a crash mid-write leaves the previous good file intact.
        let tempURL = sessionsDirectory
            .appendingPathComponent("session.json.tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: tempURL)
    }

    public func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return }
        try FileManager.default.removeItem(at: sessionsDirectory)
    }

    public func readJournalRecords(relativePath: String) throws -> [JournalRecord] {
        let url = journalURL(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileCommandJournal(url: url).readAll()
    }

    public func makeJournal(relativePath: String) throws -> any CommandJournal {
        try ensureDirectory()
        return try FileCommandJournal(url: journalURL(relativePath: relativePath))
    }

    /// The absolute URL of the WAL at `relativePath`.
    public func journalURL(relativePath: String) -> URL {
        sessionsDirectory.appendingPathComponent(relativePath)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: sessionsDirectory, withIntermediateDirectories: true)
    }
}

/// RAM-only persistence for tests and headless replay. Same contract, no disk.
public final class InMemorySessionPersistence: SessionPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SessionState?
    private var journals: [String: InMemoryCommandJournal] = [:]

    public init(state: SessionState? = nil) { self.state = state }

    public func loadState() throws -> SessionState {
        lock.withLock { state ?? SessionState() }
    }
    public func saveState(_ state: SessionState) throws {
        lock.withLock { self.state = state }
    }
    public func deleteAll() throws {
        lock.withLock { state = nil; journals.removeAll() }
    }
    public func readJournalRecords(relativePath: String) throws -> [JournalRecord] {
        try journal(at: relativePath).readAll()
    }
    public func makeJournal(relativePath: String) throws -> any CommandJournal {
        journal(at: relativePath)
    }

    private func journal(at relativePath: String) -> InMemoryCommandJournal {
        lock.withLock {
            if let existing = journals[relativePath] { return existing }
            let created = InMemoryCommandJournal()
            journals[relativePath] = created
            return created
        }
    }
}
