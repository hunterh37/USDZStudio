import XCTest
@testable import DiagnosticsKit

/// A sink that always fails — exercises the swallow-on-failure policy.
private final class FailingSink: BreadcrumbSink, @unchecked Sendable {
    struct Boom: Error {}
    func write(_ crumbs: [Breadcrumb]) throws { throw Boom() }
}

final class DiagnosticsKitTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func crumb(seq: UInt64 = 0, category: BreadcrumbCategory = .lifecycle,
                       level: BreadcrumbLevel = .info, message: String = "m",
                       metadata: [String: String] = [:]) -> Breadcrumb {
        Breadcrumb(seq: seq, timestamp: Date(timeIntervalSince1970: 1_750_000_000),
                   category: category, level: level, message: message, metadata: metadata)
    }

    // MARK: - Breadcrumb model

    func testBreadcrumbCodableRoundTrip() throws {
        let original = crumb(seq: 7, category: "custom.area", level: .error,
                             message: "boom", metadata: ["key": "value"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Breadcrumb.self, from: encoder.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testCategoryLiteralAndDescription() {
        let category: BreadcrumbCategory = "edit.command"
        XCTAssertEqual(category, .command)
        XCTAssertEqual(category.description, "edit.command")
        XCTAssertEqual(BreadcrumbCategory(rawValue: "crash"), .crash)
        XCTAssertEqual(BreadcrumbCategory.lifecycle.rawValue, "app.lifecycle")
        XCTAssertEqual(BreadcrumbCategory.action.rawValue, "ui.action")
        XCTAssertEqual(BreadcrumbCategory.mcp.rawValue, "agent.mcp")
    }

    func testLevelOrdering() {
        XCTAssertLessThan(BreadcrumbLevel.debug, .info)
        XCTAssertLessThan(BreadcrumbLevel.info, .warning)
        XCTAssertLessThan(BreadcrumbLevel.warning, .error)
        XCTAssertLessThan(BreadcrumbLevel.error, .fault)
        XCTAssertFalse(BreadcrumbLevel.fault < .debug)
    }

    func testOSLogTypeMapping() {
        for level in BreadcrumbLevel.allCases {
            _ = BreadcrumbLogger.osLogType(for: level) // total: no traps, all branches
        }
        XCTAssertEqual(BreadcrumbLogger.osLogType(for: .fault), .fault)
        XCTAssertEqual(BreadcrumbLogger.osLogType(for: .debug), .debug)
    }

    // MARK: - InMemory sink

    func testInMemorySinkPreservesOrder() throws {
        let sink = InMemoryBreadcrumbSink()
        try sink.write([crumb(seq: 0), crumb(seq: 1)])
        try sink.write([crumb(seq: 2)])
        XCTAssertEqual(sink.crumbs.map(\.seq), [0, 1, 2])
    }

    // MARK: - File sink

    func testFileSinkAppendAndReadBack() throws {
        let url = tempDir.appendingPathComponent("session.log")
        let sink = FileBreadcrumbSink(url: url)
        try sink.write([crumb(seq: 0), crumb(seq: 1, level: .warning)])
        try sink.write([]) // empty batch is a no-op
        try sink.write([crumb(seq: 2, category: .mcp, metadata: ["tool": "save"])])
        let read = try FileBreadcrumbSink.read(url: url)
        XCTAssertEqual(read.map(\.seq), [0, 1, 2])
        XCTAssertEqual(read[2].metadata["tool"], "save")
    }

    func testFileSinkReadEmptyFile() throws {
        let url = tempDir.appendingPathComponent("empty.log")
        _ = FileBreadcrumbSink(url: url) // creates the file
        XCTAssertEqual(try FileBreadcrumbSink.read(url: url), [])
    }

    func testFileSinkReadDiscardsTornFinalLine() throws {
        let url = tempDir.appendingPathComponent("torn.log")
        let sink = FileBreadcrumbSink(url: url)
        try sink.write([crumb(seq: 0)])
        var data = try Data(contentsOf: url)
        data.append(Data("{\"seq\":1,\"trunc".utf8)) // torn write, no newline
        try data.write(to: url)
        XCTAssertEqual(try FileBreadcrumbSink.read(url: url).map(\.seq), [0])
    }

    func testFileSinkReadSkipsUndecodableCompleteLine() throws {
        let url = tempDir.appendingPathComponent("mixed.log")
        let sink = FileBreadcrumbSink(url: url)
        try sink.write([crumb(seq: 0)])
        var data = try Data(contentsOf: url)
        data.append(Data("{\"not\":\"a crumb\"}\n".utf8))
        try data.write(to: url)
        try sink.write([crumb(seq: 2)])
        XCTAssertEqual(try FileBreadcrumbSink.read(url: url).map(\.seq), [0, 2])
    }

    func testFileSinkReusesExistingFile() throws {
        let url = tempDir.appendingPathComponent("reuse.log")
        try FileBreadcrumbSink(url: url).write([crumb(seq: 0)])
        try FileBreadcrumbSink(url: url).write([crumb(seq: 1)]) // re-open appends
        XCTAssertEqual(try FileBreadcrumbSink.read(url: url).count, 2)
    }

    // MARK: - Logger

    func testLoggerAssignsMonotonicSequence() {
        let sink = InMemoryBreadcrumbSink()
        let logger = BreadcrumbLogger(sink: sink, flushInterval: nil)
        logger.log(.command, "a")
        logger.log(.command, "b")
        logger.log(.action, level: .debug, "c", metadata: ["id": "x"])
        logger.flush()
        XCTAssertEqual(sink.crumbs.map(\.seq), [0, 1, 2])
        XCTAssertEqual(sink.crumbs.map(\.message), ["a", "b", "c"])
        XCTAssertEqual(sink.crumbs[2].metadata["id"], "x")
    }

    func testLoggerFlushesImmediatelyAtWarningAndAbove() {
        let sink = InMemoryBreadcrumbSink()
        let logger = BreadcrumbLogger(sink: sink, flushInterval: nil)
        logger.log(.lifecycle, "buffered")           // .info: stays buffered
        XCTAssertTrue(sink.crumbs.isEmpty)
        logger.log(.crash, level: .warning, "flushed") // triggers a flush of both
        XCTAssertEqual(sink.crumbs.map(\.message), ["buffered", "flushed"])
    }

    func testLoggerFlushesWhenBufferFull() {
        let sink = InMemoryBreadcrumbSink()
        let logger = BreadcrumbLogger(sink: sink, maxBuffered: 3, flushInterval: nil)
        logger.log(.command, "1"); logger.log(.command, "2")
        XCTAssertTrue(sink.crumbs.isEmpty)
        logger.log(.command, "3") // hits maxBuffered
        XCTAssertEqual(sink.crumbs.count, 3)
    }

    func testLoggerIntervalFlush() async throws {
        let sink = InMemoryBreadcrumbSink()
        let logger = BreadcrumbLogger(sink: sink, flushInterval: .milliseconds(20))
        logger.log(.lifecycle, "tick")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.crumbs.map(\.message), ["tick"])
        logger.shutdown()
    }

    func testLoggerShutdownDrainsAndIgnoresLaterLogs() {
        let sink = InMemoryBreadcrumbSink()
        let logger = BreadcrumbLogger(sink: sink, flushInterval: nil)
        logger.log(.lifecycle, "final")
        logger.shutdown()
        XCTAssertEqual(sink.crumbs.map(\.message), ["final"])
        logger.log(.lifecycle, "ignored")
        logger.flush()
        XCTAssertEqual(sink.crumbs.count, 1)
    }

    func testLoggerSwallowsSinkFailures() {
        let logger = BreadcrumbLogger(sink: FailingSink(), flushInterval: nil)
        logger.log(.crash, level: .fault, "must not throw or trap")
        logger.flush() // no crash: failure policy is drop-and-continue
    }

    func testLoggerOSLogMirrorPath() {
        // Exercises the mirror branch; unified-log output isn't asserted.
        let sink = InMemoryBreadcrumbSink()
        let logger = BreadcrumbLogger(sink: sink, flushInterval: nil, mirrorToOSLog: true)
        logger.log(.command, level: .error, "mirrored")
        XCTAssertEqual(sink.crumbs.count, 1)
    }

    func testLoggerConcurrentLoggingKeepsAllCrumbsUniquelySequenced() async {
        let sink = InMemoryBreadcrumbSink()
        let logger = BreadcrumbLogger(sink: sink, flushInterval: nil)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { logger.log(.command, "c\(i)") }
            }
        }
        logger.flush()
        XCTAssertEqual(Set(sink.crumbs.map(\.seq)).count, 100)
    }

    func testLoggerInjectedClockStampsCrumbs() {
        let sink = InMemoryBreadcrumbSink()
        let fixed = Date(timeIntervalSince1970: 42)
        let logger = BreadcrumbLogger(sink: sink, flushInterval: nil, now: { fixed })
        logger.log(.lifecycle, "t")
        logger.flush()
        XCTAssertEqual(sink.crumbs.first?.timestamp, fixed)
    }

    // MARK: - SessionLogStore

    func testStoreCreatesLogWithChronologicalName() throws {
        let store = SessionLogStore(root: tempDir.appendingPathComponent("Logs"))
        let id = UUID()
        let url = try store.createSessionLog(sessionID: id,
                                             date: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-\(id.uuidString).log"))
        XCTAssertEqual(url.lastPathComponent.prefix(9).count, 9) // yyyyMMdd-
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testStoreListsLogsOldestFirstIgnoringNonLogs() throws {
        let root = tempDir.appendingPathComponent("Logs")
        let store = SessionLogStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["20260102-000000-b.log", "20260101-000000-a.log", "session.live"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path,
                                           contents: Data("x".utf8))
        }
        XCTAssertEqual(try store.sessionLogURLs().map(\.lastPathComponent),
                       ["20260101-000000-a.log", "20260102-000000-b.log"])
    }

    func testStoreListReturnsEmptyWhenRootMissing() throws {
        let store = SessionLogStore(root: tempDir.appendingPathComponent("nope"))
        XCTAssertEqual(try store.sessionLogURLs(), [])
    }

    func testStoreDefaultRootUnderApplicationSupport() {
        let root = SessionLogStore(root: nil).root
        XCTAssertTrue(root.path.contains("USDZStudio"))
        XCTAssertEqual(root.lastPathComponent, "Logs")
        XCTAssertEqual(SessionLogStore.defaultRoot(fileManager: .default).lastPathComponent, "Logs")
    }

    private func seedLogs(_ names: [String], in root: URL, bytes: Int = 1) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path,
                                           contents: Data(repeating: 0x61, count: bytes))
        }
    }

    func testRetentionByCountDeletesOldestFirst() throws {
        let root = tempDir.appendingPathComponent("Logs")
        let store = SessionLogStore(root: root)
        try seedLogs((1...5).map { "2026010\($0)-000000-s.log" }, in: root)
        try store.enforceRetention(maxSessions: 3, maxTotalBytes: .max)
        XCTAssertEqual(try store.sessionLogURLs().map(\.lastPathComponent),
                       ["20260103-000000-s.log", "20260104-000000-s.log", "20260105-000000-s.log"])
    }

    func testRetentionByBytes() throws {
        let root = tempDir.appendingPathComponent("Logs")
        let store = SessionLogStore(root: root)
        try seedLogs((1...4).map { "2026010\($0)-000000-s.log" }, in: root, bytes: 100)
        try store.enforceRetention(maxSessions: 100, maxTotalBytes: 250)
        XCTAssertEqual(try store.sessionLogURLs().count, 2) // 400 → 200 bytes
    }

    func testRetentionNeverDeletesCurrentLog() throws {
        let root = tempDir.appendingPathComponent("Logs")
        let store = SessionLogStore(root: root)
        try seedLogs(["20260101-000000-cur.log", "20260102-000000-b.log"], in: root)
        let current = root.appendingPathComponent("20260101-000000-cur.log")
        try store.enforceRetention(maxSessions: 1, maxTotalBytes: .max, keeping: current)
        let names = try store.sessionLogURLs().map(\.lastPathComponent)
        XCTAssertTrue(names.contains("20260101-000000-cur.log"))
        XCTAssertEqual(names.count, 1)
    }

    func testRetentionNoOpUnderLimits() throws {
        let root = tempDir.appendingPathComponent("Logs")
        let store = SessionLogStore(root: root)
        try seedLogs(["20260101-000000-a.log"], in: root)
        try store.enforceRetention(maxSessions: 10, maxTotalBytes: .max)
        XCTAssertEqual(try store.sessionLogURLs().count, 1)
    }

    // MARK: - CrashSentinel

    func testSentinelCleanLifecycleReportsNoCrash() throws {
        let sentinel = CrashSentinel(root: tempDir)
        XCTAssertNil(try sentinel.checkPreviousAndArm(sessionID: UUID(), logFileName: "a.log"))
        sentinel.disarm()
        XCTAssertNil(try sentinel.checkPreviousAndArm(sessionID: UUID(), logFileName: "b.log"))
        sentinel.disarm()
    }

    func testSentinelDetectsUncleanExitWithPayload() throws {
        let sentinel = CrashSentinel(root: tempDir)
        let firstID = UUID()
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertNil(try sentinel.checkPreviousAndArm(sessionID: firstID,
                                                      logFileName: "first.log", date: started))
        // No disarm — simulated crash. Next launch sees the prior session.
        let prior = try sentinel.checkPreviousAndArm(sessionID: UUID(), logFileName: "second.log")
        XCTAssertEqual(prior, CrashSentinel.PriorCrash(sessionID: firstID,
                                                       logFileName: "first.log",
                                                       startedAt: started))
    }

    func testSentinelCorruptPayloadStillReportsCrash() throws {
        let sentinel = CrashSentinel(root: tempDir)
        try Data("garbage".utf8).write(to: sentinel.url)
        let prior = try sentinel.checkPreviousAndArm(sessionID: UUID(), logFileName: "x.log")
        XCTAssertEqual(prior?.logFileName, "unknown")
        XCTAssertEqual(prior?.startedAt, .distantPast)
    }

    func testSentinelDisarmIsIdempotent() {
        let sentinel = CrashSentinel(root: tempDir)
        sentinel.disarm() // nothing armed: must not throw or trap
        sentinel.disarm()
    }
}
