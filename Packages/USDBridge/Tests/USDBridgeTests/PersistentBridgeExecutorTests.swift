import Testing
import Foundation
import USDCore
@testable import USDBridge

// MARK: Pure framing

@Suite("PersistentBridgeExecutor framing")
struct PersistentFramingTests {

    @Test func parsesOKHeader() {
        let frame = PersistentBridgeExecutor.parseFrameHeader("OK 42")
        #expect(frame?.status == .ok)
        #expect(frame?.length == 42)
    }

    @Test func parsesERRHeader() {
        #expect(PersistentBridgeExecutor.parseFrameHeader("ERR 7")?.status == .err)
    }

    @Test func rejectsMalformedHeaders() {
        #expect(PersistentBridgeExecutor.parseFrameHeader("OK") == nil)          // no length
        #expect(PersistentBridgeExecutor.parseFrameHeader("WAT 3") == nil)       // bad status
        #expect(PersistentBridgeExecutor.parseFrameHeader("OK -1") == nil)       // negative
        #expect(PersistentBridgeExecutor.parseFrameHeader("OK x") == nil)        // non-numeric
        #expect(PersistentBridgeExecutor.parseFrameHeader("OK 3 4") == nil)      // extra field
        #expect(PersistentBridgeExecutor.parseFrameHeader("") == nil)
    }

    @Test func encodesRequestAsNewlineTerminatedJSON() throws {
        let data = PersistentBridgeExecutor.encodeRequest(op: "snapshot", path: "/tmp/a b.usdz")
        #expect(data.last == 0x0A)
        let obj = try JSONSerialization.jsonObject(
            with: data.dropLast()) as? [String: String]
        #expect(obj?["op"] == "snapshot")
        #expect(obj?["path"] == "/tmp/a b.usdz")   // spaces survive the round-trip
    }

    @Test func encodesPathlessRequest() throws {
        let data = PersistentBridgeExecutor.encodeRequest(op: "ping", path: nil)
        let obj = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: String]
        #expect(obj?["op"] == "ping")
        #expect(obj?["path"] == nil)
    }

    @Test func escapesTrickyPaths() throws {
        // A path with a quote and backslash must not corrupt the JSON line.
        let path = #"/tmp/we"ird\name.usdz"#
        let data = PersistentBridgeExecutor.encodeRequest(op: "snapshot", path: path)
        let obj = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: String]
        #expect(obj?["path"] == path)
    }
}

// MARK: Fake-worker plumbing (deterministic, no usd-core)

/// A shell script standing in for the Python worker: it speaks the frame
/// protocol so the executor's request/response, warm-reuse, error, and fallback
/// paths are exercised without needing usd-core installed.
@Suite("PersistentBridgeExecutor plumbing")
struct PersistentPlumbingTests {

    /// Writes a fake interpreter. `serverBody` runs when invoked as the server
    /// (arg is the server script); a `stage_snapshot.py` arg emits a one-shot
    /// fallback payload, and `-c` (the availability probe) exits cleanly.
    private func makeFake(serverBody: String) throws -> (python: String, server: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pworker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let python = dir.appendingPathComponent("python3").path
        let script = """
        #!/bin/sh
        case "$1" in
          -c) exit 0 ;;
          *stage_snapshot.py) printf '{"prims":[{"path":"/FB"}]}'; exit 0 ;;
        esac
        \(serverBody)
        """
        try script.write(toFile: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python)
        // The server script only needs to exist and sit beside a stage_snapshot.py.
        let server = dir.appendingPathComponent("bridge_server.py").path
        try "unused".write(toFile: server, atomically: true, encoding: .utf8)
        try "unused".write(toFile: dir.appendingPathComponent("stage_snapshot.py").path,
                           atomically: true, encoding: .utf8)
        return (python, server)
    }

    private func happyServer(startsFile: String) -> String {
        """
        echo start >> "\(startsFile)"
        while IFS= read -r line; do
          case "$line" in
            *shutdown*) exit 0 ;;
            *ping*) p='{"ok": true}' ;;
            *) p='{"prims":[{"path":"/A"}]}' ;;
          esac
          printf 'OK %d\\n' ${#p}
          printf '%s' "$p"
        done
        """
    }

    @Test func snapshotReturnsFramedPayloadAndDecodes() async throws {
        let starts = FileManager.default.temporaryDirectory
            .appendingPathComponent("starts-\(UUID().uuidString)").path
        let fake = try makeFake(serverBody: happyServer(startsFile: starts))
        let executor = PersistentBridgeExecutor(pythonPath: fake.python, serverScriptPath: fake.server)

        let stage = try await BridgedStage.open(
            url: URL(fileURLWithPath: "/tmp/x.usdz"), executor: executor)
        #expect(stage.prim(at: PrimPath("/A")!) != nil)
        await executor.shutdown()
    }

    @Test func warmWorkerServesManyOpensFromOneProcess() async throws {
        let starts = FileManager.default.temporaryDirectory
            .appendingPathComponent("starts-\(UUID().uuidString)").path
        let fake = try makeFake(serverBody: happyServer(startsFile: starts))
        let executor = PersistentBridgeExecutor(pythonPath: fake.python, serverScriptPath: fake.server)

        for _ in 0..<3 {
            _ = try await executor.snapshotJSON(forFileAt: URL(fileURLWithPath: "/tmp/x.usdz"))
        }
        await executor.shutdown()

        // The whole point: one interpreter served all three opens.
        let launches = (try String(contentsOfFile: starts, encoding: .utf8))
            .split(separator: "\n").count
        #expect(launches == 1)
    }

    @Test func pingReportsAvailable() async throws {
        let starts = FileManager.default.temporaryDirectory
            .appendingPathComponent("starts-\(UUID().uuidString)").path
        let fake = try makeFake(serverBody: happyServer(startsFile: starts))
        let executor = PersistentBridgeExecutor(pythonPath: fake.python, serverScriptPath: fake.server)
        #expect(await executor.checkAvailability().isAvailable)
        await executor.shutdown()
    }

    @Test func cleanErrFramePropagatesWithoutFallback() async throws {
        // An ERR frame is a real application error (e.g. a malformed file); it
        // must surface as executionFailed, not silently retry via the fallback.
        let fake = try makeFake(serverBody: """
        while IFS= read -r line; do
          m='boom: bad file'
          printf 'ERR %d\\n' ${#m}
          printf '%s' "$m"
        done
        """)
        let executor = PersistentBridgeExecutor(pythonPath: fake.python, serverScriptPath: fake.server)
        do {
            _ = try await executor.snapshotJSON(forFileAt: URL(fileURLWithPath: "/tmp/x.usdz"))
            Issue.record("expected throw")
        } catch let error as BridgeError {
            guard case .executionFailed(let traceback) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(traceback.contains("boom"))
        }
        await executor.shutdown()
    }

    @Test func transportFailureFallsBackToOneShot() async throws {
        // The worker emits a garbage header then dies — a transport failure. The
        // open must still succeed via the one-shot fallback (the /FB payload).
        let fake = try makeFake(serverBody: """
        read line
        printf 'GARBAGE-not-a-frame\\n'
        exit 1
        """)
        let executor = PersistentBridgeExecutor(pythonPath: fake.python, serverScriptPath: fake.server)
        let stage = try await BridgedStage.open(
            url: URL(fileURLWithPath: "/tmp/x.usdz"), executor: executor)
        #expect(stage.prim(at: PrimPath("/FB")!) != nil)   // came from the fallback
        await executor.shutdown()
    }

    @Test func launchFailureFallsBack() async throws {
        // A python path that cannot launch as a worker still opens via fallback…
        // which also can't launch, so the error is the subprocess baseline's.
        let executor = PersistentBridgeExecutor(
            pythonPath: "/nonexistent/python3", serverScriptPath: "/nonexistent/bridge_server.py")
        await #expect(throws: BridgeError.self) {
            _ = try await executor.snapshotJSON(forFileAt: URL(fileURLWithPath: "/tmp/x.usdz"))
        }
    }

    @Test func locatorInitReturnsNilWithoutInterpreter() {
        struct NoneChecker: FileExistenceChecking {
            func isExecutableFile(atPath path: String) -> Bool { false }
        }
        let locator = PythonRuntimeLocator(environment: [:], checker: NoneChecker())
        #expect(PersistentBridgeExecutor(locator: locator, serverScriptPath: "s.py") == nil)
    }
}

// MARK: Real usd-core integration (gated)

@Suite("PersistentBridgeExecutor — real usd-core")
struct PersistentRealIntegrationTests {

    @Test func opensRealFileTwiceThroughOneWorker() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let server = repoRoot.appendingPathComponent("Resources/Python/bridge_server.py").path
        guard let executor = PersistentBridgeExecutor(serverScriptPath: server),
              await executor.checkAvailability().isAvailable else {
            return   // no usd-core here — graceful skip (CI has it)
        }
        let usda = """
        #usda 1.0
        (
            defaultPrim = "Car"
            upAxis = "Y"
        )
        def Xform "Car" {
            def Mesh "Wheel" {}
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbridge-\(UUID().uuidString).usda")
        try usda.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // Two opens through the same resident worker return identical structure.
        for _ in 0..<2 {
            let stage = try await BridgedStage.open(url: url, executor: executor)
            #expect(stage.metadata.defaultPrim == "Car")
            #expect(stage.prim(at: PrimPath("/Car/Wheel")!)?.typeName == "Mesh")
        }

        // A bad file returns an error but must NOT kill the worker…
        let missing = url.deletingLastPathComponent()
            .appendingPathComponent("nope-\(UUID().uuidString).usda")
        await #expect(throws: BridgeError.self) {
            _ = try await executor.snapshotJSON(forFileAt: missing)
        }
        // …the next open still succeeds on the same worker.
        let after = try await BridgedStage.open(url: url, executor: executor)
        #expect(after.metadata.defaultPrim == "Car")
        await executor.shutdown()
    }
}
