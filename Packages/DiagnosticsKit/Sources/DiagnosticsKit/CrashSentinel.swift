import Foundation

/// Crash detection via a live-session sentinel — the same passive pattern as
/// `EditingKit.SessionStore`'s `session.live`, deliberately instead of signal
/// handlers or `NSSetUncaughtExceptionHandler`: nothing in a Foundation/JSON
/// stack is async-signal-safe, and a bad in-process crash handler can corrupt
/// Apple's own crash reports or deadlock. The sentinel gives the same answer
/// ("did the last session end cleanly?") with zero crash-time code.
///
/// Lifecycle: `checkPreviousAndArm` on launch (reports the previous session's
/// unclean exit, if any, then arms for this one); `disarm` on clean terminate.
public struct CrashSentinel: Sendable {
    /// What was found on launch: the previous session that never disarmed.
    public struct PriorCrash: Codable, Equatable, Sendable {
        public let sessionID: UUID
        /// File name (not path — the root can move) of that session's log,
        /// where the final breadcrumbs before the crash live.
        public let logFileName: String
        public let startedAt: Date

        public init(sessionID: UUID, logFileName: String, startedAt: Date) {
            self.sessionID = sessionID
            self.logFileName = logFileName
            self.startedAt = startedAt
        }
    }

    public let url: URL

    // FileManager isn't Sendable — use `.default` per call, never stored.
    private var fileManager: FileManager { .default }

    /// - Parameter root: the logs directory (share it with `SessionLogStore`).
    public init(root: URL) {
        self.url = root.appendingPathComponent("session.live", isDirectory: false)
    }

    /// If a sentinel from a previous session exists, returns its payload
    /// (unclean exit), then writes this session's sentinel. A sentinel that
    /// exists but can't be decoded still means "did not exit cleanly", so it
    /// is reported with placeholder identity rather than ignored.
    public func checkPreviousAndArm(sessionID: UUID, logFileName: String,
                                    date: Date = Date()) throws -> PriorCrash? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var prior: PriorCrash?
        if let data = try? Data(contentsOf: url) {
            prior = (try? decoder.decode(PriorCrash.self, from: data))
                // Corrupt sentinel (torn write during arm): still a dirty exit.
                ?? PriorCrash(sessionID: UUID(uuid: UUID_NULL), logFileName: "unknown",
                              startedAt: .distantPast)
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = PriorCrash(sessionID: sessionID, logFileName: logFileName,
                                 startedAt: date)
        try encoder.encode(payload).write(to: url, options: .atomic)
        return prior
    }

    /// Removes the sentinel — call on clean terminate, after the final flush.
    public func disarm() {
        try? fileManager.removeItem(at: url)
    }
}
