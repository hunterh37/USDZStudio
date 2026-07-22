import Foundation
import AppKit
import DiagnosticsKit

/// Composition-root wiring for the session breadcrumb log
/// (specs/diagnostics-logging.md). Owns the pieces the app needs exactly once:
/// the per-session log file, the buffered logger, the crash sentinel, and log
/// retention. Created by `AppDelegate` at launch and torn down on terminate —
/// kept out of `USDZStudioApp` so the app struct stays thin wiring.
///
/// Everything here is best-effort: diagnostics must never block or fail a
/// launch, so setup errors degrade to an in-memory (no-file) logger.
@MainActor
final class DiagnosticsBootstrap {
    let logger: BreadcrumbLogger
    private let sentinel: CrashSentinel
    private let store: SessionLogStore
    private let sessionLogURL: URL?

    init() {
        let store = SessionLogStore()
        self.store = store
        let sessionID = UUID()
        let sentinel = CrashSentinel(root: store.root)
        self.sentinel = sentinel

        var logURL: URL?
        var sink: any BreadcrumbSink = InMemoryBreadcrumbSink() // degraded fallback
        if let url = try? store.createSessionLog(sessionID: sessionID) {
            logURL = url
            sink = FileBreadcrumbSink(url: url)
        }
        self.sessionLogURL = logURL
        // Mirror to the unified log so breadcrumbs also show in Console.app
        // alongside any macOS crash report for the same session.
        let logger = BreadcrumbLogger(sink: sink, mirrorToOSLog: true)
        self.logger = logger

        logger.log(.lifecycle, "launch", metadata: [
            "log": logURL?.lastPathComponent ?? "in-memory",
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])

        // Crash detection: a surviving sentinel means the previous session
        // never exited cleanly. Record it in THIS session's log (with the prior
        // log's file name — that file's tail is the trail to the crash).
        // `try?` flattens the optional: nil here means "no prior crash" OR
        // "sentinel unreadable" — both safely silent.
        if let crash = try? sentinel.checkPreviousAndArm(
            sessionID: sessionID, logFileName: logURL?.lastPathComponent ?? "in-memory") {
            logger.log(.crash, level: .warning, "previous session exited uncleanly",
                       metadata: ["priorLog": crash.logFileName,
                                  "priorSession": crash.sessionID.uuidString,
                                  "priorStartedAt": "\(crash.startedAt)"])
        }

        // Retention: keep the folder bounded (20 sessions / 20 MB), never
        // touching the file this session is writing.
        try? store.enforceRetention(keeping: logURL)
    }

    /// Clean-terminate path: final lifecycle crumb, synchronous drain, disarm.
    /// Order matters — the sentinel must only disappear after the flush, so a
    /// kill during shutdown still reads as an unclean exit.
    func shutdown() {
        logger.log(.lifecycle, "terminate")
        logger.shutdown()
        sentinel.disarm()
    }

    /// Help ▸ Reveal Diagnostics Logs: opens the Logs folder in Finder,
    /// selecting this session's log when there is one.
    func revealLogsInFinder() {
        logger.log(.action, "reveal diagnostics logs")
        if let sessionLogURL {
            NSWorkspace.shared.activateFileViewerSelecting([sessionLogURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([store.root])
        }
    }
}
