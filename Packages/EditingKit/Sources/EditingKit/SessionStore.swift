import Foundation
import USDCore

/// Owns the on-disk layout of crash-recovery sessions and turns a leftover WAL
/// from a killed process back into a replayable `RecoveryPlan`.
///
/// Layout (under `root`, typically Application Support/OpenUSDZEditor/Sessions):
/// ```
/// <root>/<sessionID>/journal.wal    ← the write-ahead log
/// <root>/<sessionID>/session.live   ← sentinel: present ⇒ process didn't exit cleanly
/// ```
/// On open, a session writes its sentinel. On a *clean* quit the app calls
/// `finish(_:)`, which removes the whole directory. If the app is killed, the
/// sentinel survives, so on relaunch `recoverableSessions()` finds the session,
/// reads the WAL, and hands back the last-saved document plus the records to
/// replay against it.
public final class SessionStore: Sendable {
    /// Directory that holds all per-document session folders.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Default location under the user's Application Support directory.
    public static func defaultStore(
        appName: String = "OpenUSDZEditor",
        fileManager: FileManager = .default
    ) -> SessionStore {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return SessionStore(root: base
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true))
    }

    /// A live editing session: its journal plus the sentinel lifecycle.
    public final class Session: Sendable {
        public let id: String
        public let directory: URL
        public let journal: FileCommandJournal
        let sentinel: URL

        init(id: String, directory: URL, journal: FileCommandJournal, sentinel: URL) {
            self.id = id
            self.directory = directory
            self.journal = journal
            self.sentinel = sentinel
        }
    }

    /// A recoverable session found on relaunch: which document to reopen and
    /// the records to replay against it.
    public struct RecoveryPlan: Sendable, Equatable {
        public let sessionID: String
        public let directory: URL
        /// The document the WAL's last checkpoint was taken over (`nil` for an
        /// untitled document that was never saved).
        public let sourceURL: URL?
        /// Records after the last checkpoint — feed to `CommandStack.recovered`.
        public let records: [JournalRecord]

        /// `true` when there is actual unsaved work to restore (some sessions
        /// hold only a bare checkpoint — nothing to recover).
        public var hasWork: Bool {
            records.contains { if case .command = $0 { return true }; return false }
        }
    }

    private static let journalName = "journal.wal"
    private static let sentinelName = "session.live"

    /// Starts a new session for `sourceURL`, creating its directory, WAL, and
    /// live sentinel.
    public func startSession(
        for sourceURL: URL?,
        id: String = UUID().uuidString,
        fileManager: FileManager = .default
    ) throws -> Session {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let journal = try FileCommandJournal(url: dir.appendingPathComponent(Self.journalName))
        let sentinel = dir.appendingPathComponent(Self.sentinelName)
        fileManager.createFile(atPath: sentinel.path,
                               contents: Data("\(ProcessInfo.processInfo.processIdentifier)".utf8))
        return Session(id: id, directory: dir, journal: journal, sentinel: sentinel)
    }

    /// Marks `session` cleanly finished — removes its directory so it is not
    /// offered for recovery. Call on a graceful document close / app quit.
    public func finish(_ session: Session, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: session.directory)
    }

    /// Scans `root` for sessions left behind by a killed process (sentinel
    /// present) and turns each into a `RecoveryPlan`. Sessions with an empty or
    /// unreadable WAL are skipped (and their stale directories swept away).
    public func recoverableSessions(fileManager: FileManager = .default) -> [RecoveryPlan] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var plans: [RecoveryPlan] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let sentinel = dir.appendingPathComponent(Self.sentinelName)
            guard fileManager.fileExists(atPath: sentinel.path) else { continue }
            let journalURL = dir.appendingPathComponent(Self.journalName)
            guard let journal = try? FileCommandJournal(url: journalURL),
                  let all = try? journal.readAll(), !all.isEmpty else {
                try? fileManager.removeItem(at: dir)
                continue
            }
            plans.append(Self.plan(for: dir, records: all))
        }
        return plans
    }

    /// Splits a full WAL into the last checkpoint's document plus the records
    /// after it — the exact slice `CommandStack.recovered` expects.
    static func plan(for directory: URL, records: [JournalRecord]) -> RecoveryPlan {
        var sourceURL: URL?
        var tail: [JournalRecord] = []
        for record in records {
            if case let .checkpoint(url) = record {
                sourceURL = url
                tail.removeAll(keepingCapacity: true)
            } else {
                tail.append(record)
            }
        }
        return RecoveryPlan(sessionID: directory.lastPathComponent,
                            directory: directory, sourceURL: sourceURL, records: tail)
    }

    /// Discards a recovered (or declined) session's directory.
    public func discard(_ plan: RecoveryPlan, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: plan.directory)
    }

    /// Removes *every* session directory under `root` — the active one plus any
    /// left behind by prior launches — so a subsequent `recoverableSessions()`
    /// finds nothing to restore. Backs the File ▸ "Reset Session" action.
    ///
    /// Best-effort and total: it sweeps the whole tree (WALs, sentinels, and
    /// envelope `session.json` files alike) rather than only sentinel-bearing
    /// sessions, so it also clears bare/partial directories that
    /// `recoverableSessions()` would skip. A directory that can't be removed is
    /// left in place rather than raising — resetting must never fail the caller.
    /// Returns the number of top-level session directories removed.
    @discardableResult
    public func reset(fileManager: FileManager = .default) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for dir in entries where (try? fileManager.removeItem(at: dir)) != nil {
            removed += 1
        }
        return removed
    }

    /// Reopens the write-ahead log for a recovered `plan` so the restored
    /// document keeps appending to the *same* session (continued crash-safety and
    /// session capture) instead of starting a fresh one.
    public func journal(for plan: RecoveryPlan) throws -> FileCommandJournal {
        try FileCommandJournal(url: plan.directory.appendingPathComponent(Self.journalName))
    }
}
