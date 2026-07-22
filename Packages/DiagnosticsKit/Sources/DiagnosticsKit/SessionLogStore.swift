import Foundation

/// Owns the on-disk layout of per-session breadcrumb logs and their retention.
///
/// Layout (under `root`, typically Application Support/USDZStudio/Logs):
/// ```
/// <root>/<yyyyMMdd-HHmmss>-<sessionID>.log   ← one JSON Lines file per session
/// <root>/session.live                        ← CrashSentinel's sentinel
/// ```
/// The timestamp prefix makes lexicographic order chronological, so retention
/// and "newest first" listings never parse dates.
public struct SessionLogStore: Sendable {
    public let root: URL

    // FileManager isn't Sendable, so it is never stored — `.default` is used
    // per call, the same discipline as EditingKit.SessionStore.
    private var fileManager: FileManager { .default }

    /// - Parameter root: injectable for temp-dir tests; defaults to
    ///   `Application Support/USDZStudio/Logs`.
    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot(fileManager: .default)
    }

    static func defaultRoot(appName: String = "USDZStudio",
                            fileManager: FileManager) -> URL {
        // Same fallback discipline as EditingKit.SessionStore.defaultStore.
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    /// Creates (touching the directory into existence) this session's log file
    /// and returns its URL: `<root>/<yyyyMMdd-HHmmss>-<sessionID>.log`.
    public func createSessionLog(sessionID: UUID, date: Date = Date()) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(formatter.string(from: date))-\(sessionID.uuidString).log"
        return root.appendingPathComponent(name, isDirectory: false)
    }

    /// All session log files, oldest first (lexicographic = chronological).
    public func sessionLogURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Deletes oldest-first until at most `maxSessions` logs remain AND their
    /// total size is at most `maxTotalBytes`. `keeping` (the current session's
    /// log) is never deleted. Best-effort: individual delete failures are
    /// skipped — retention must never fail a launch.
    public func enforceRetention(maxSessions: Int = 20,
                                 maxTotalBytes: Int = 20 * 1_048_576,
                                 keeping current: URL? = nil) throws {
        var logs = try sessionLogURLs()
        var totalBytes = logs.reduce(0) { $0 + fileSize($1) }
        var index = 0
        while index < logs.count,
              logs.count > maxSessions || totalBytes > maxTotalBytes {
            let candidate = logs[index]
            // Compare by file name: all logs live in `root`, and URL equality
            // is unreliable across /var ↔ /private/var symlink spellings.
            if candidate.lastPathComponent == current?.lastPathComponent {
                index += 1 // never delete the live session's log
                continue
            }
            totalBytes -= fileSize(candidate)
            try? fileManager.removeItem(at: candidate)
            logs.remove(at: index)
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
