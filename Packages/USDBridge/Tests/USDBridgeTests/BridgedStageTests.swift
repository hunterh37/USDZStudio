import Testing
import Foundation
import USDCore
@testable import USDBridge

/// Mock executor: returns canned payloads without any Python.
struct MockExecutor: BridgeExecutor {
    var payload: Result<Data, BridgeError>
    var availability: BridgeAvailability = .available(pythonPath: "/mock/python3")

    func snapshotJSON(forFileAt url: URL) async throws -> Data {
        try payload.get()
    }
    func checkAvailability() async -> BridgeAvailability { availability }
}

@Suite("BridgedStage.open")
struct BridgedStageTests {

    private let goodPayload = Data(#"{"prims":[{"path":"/Root","type":"Xform"}]}"#.utf8)

    @Test(arguments: ["usdz", "usda", "usdc", "usd", "USDZ"])
    func opensSupportedExtensions(_ ext: String) async throws {
        let stage = try await BridgedStage.open(
            url: URL(fileURLWithPath: "/tmp/model.\(ext)"),
            executor: MockExecutor(payload: .success(goodPayload)))
        #expect(stage.primCount == 1)
        #expect(stage.prim(at: PrimPath("/Root")!)?.typeName == "Xform")
        #expect(stage.sourceURL?.lastPathComponent == "model.\(ext)")
        #expect(stage.metadata == StageMetadata())
        #expect(stage.rootPrims.count == 1)
    }

    @Test(arguments: ["glb", "obj", "reality", ""])
    func rejectsUnsupportedExtensions(_ ext: String) async {
        let url = URL(fileURLWithPath: ext.isEmpty ? "/tmp/model" : "/tmp/model.\(ext)")
        await #expect(throws: BridgeError.unreadableFile(path: url.path)) {
            _ = try await BridgedStage.open(url: url, executor: MockExecutor(payload: .success(goodPayload)))
        }
    }

    @Test func propagatesExecutorFailure() async {
        let boom = BridgeError.executionFailed(pythonTraceback: "Traceback: boom")
        await #expect(throws: boom) {
            _ = try await BridgedStage.open(
                url: URL(fileURLWithPath: "/tmp/model.usdz"),
                executor: MockExecutor(payload: .failure(boom)))
        }
    }

    @Test func propagatesMalformedSnapshot() async {
        await #expect(throws: BridgeError.self) {
            _ = try await BridgedStage.open(
                url: URL(fileURLWithPath: "/tmp/model.usdz"),
                executor: MockExecutor(payload: .success(Data("garbage".utf8))))
        }
    }
}

@Suite("PythonRuntimeLocator")
struct LocatorTests {

    struct StubChecker: FileExistenceChecking {
        var executables: Set<String>
        func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    }

    /// Distinguishes "exists" from "can import pxr" so the pxr-aware selection
    /// and its fallback are both exercised.
    struct CapabilityChecker: FileExistenceChecking {
        var executables: Set<String>
        var usdCapable: Set<String>
        func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
        func canImportUSD(atPath path: String) -> Bool { usdCapable.contains(path) }
    }

    @Test func environmentOverrideWinsWhenExecutable() {
        let locator = PythonRuntimeLocator(
            environment: ["DICYANIN_PYTHON": "/custom/python3"],
            checker: StubChecker(executables: ["/custom/python3", "/usr/bin/python3"]))
        #expect(locator.locate() == "/custom/python3")
        #expect(locator.candidatePaths.first == "/custom/python3")
    }

    @Test func emptyOverrideIsIgnored() {
        let locator = PythonRuntimeLocator(
            environment: ["DICYANIN_PYTHON": ""],
            checker: StubChecker(executables: ["/usr/bin/python3"]))
        #expect(locator.locate() == "/usr/bin/python3")
    }

    @Test func bundledRuntimeBeatsSystem() {
        let locator = PythonRuntimeLocator(
            environment: [:],
            bundledRuntimeRoot: "/app/Resources/Python/runtime",
            checker: StubChecker(executables: ["/app/Resources/Python/runtime/bin/python3", "/usr/bin/python3"]))
        #expect(locator.locate() == "/app/Resources/Python/runtime/bin/python3")
    }

    @Test func nothingFoundReturnsNil() {
        let locator = PythonRuntimeLocator(environment: [:], checker: StubChecker(executables: []))
        #expect(locator.locate() == nil)
        #expect(ProcessBridgeExecutor(locator: locator, scriptPath: "s.py") == nil)
    }

    // A higher-priority interpreter that exists but lacks usd-core must not be
    // chosen over a lower-priority one that can import pxr — the bug behind the
    // "No module named 'pxr'" export failure.
    @Test func skipsExistingInterpreterWithoutUSDCore() {
        let locator = PythonRuntimeLocator(
            environment: [:],
            bundledRuntimeRoot: "/app/Resources/Python/runtime",
            checker: CapabilityChecker(
                executables: ["/app/Resources/Python/runtime/bin/python3", "/usr/bin/python3"],
                usdCapable: ["/usr/bin/python3"]))
        #expect(locator.locate() == "/usr/bin/python3")
    }

    // The bundled runtime is still preferred when it has usd-core, even though a
    // lower-priority system interpreter is also capable.
    @Test func prefersHigherPriorityWhenBothCapable() {
        let locator = PythonRuntimeLocator(
            environment: [:],
            bundledRuntimeRoot: "/app/Resources/Python/runtime",
            checker: CapabilityChecker(
                executables: ["/app/Resources/Python/runtime/bin/python3", "/usr/bin/python3"],
                usdCapable: ["/app/Resources/Python/runtime/bin/python3", "/usr/bin/python3"]))
        #expect(locator.locate() == "/app/Resources/Python/runtime/bin/python3")
    }

    // When no candidate can import pxr, fall back to the first existing one so
    // the caller still surfaces an actionable pythonUnavailable error.
    @Test func fallsBackToFirstExistingWhenNoneCapable() {
        let locator = PythonRuntimeLocator(
            environment: [:],
            bundledRuntimeRoot: "/app/Resources/Python/runtime",
            checker: CapabilityChecker(
                executables: ["/opt/homebrew/bin/python3", "/usr/bin/python3"],
                usdCapable: []))
        #expect(locator.locate() == "/opt/homebrew/bin/python3")
    }

    // The default `canImportUSD` (used by pure-logic stubs) treats any
    // executable as capable.
    @Test func defaultCapabilityFollowsExecutability() {
        let checker = StubChecker(executables: ["/usr/bin/python3"])
        #expect(checker.canImportUSD(atPath: "/usr/bin/python3"))
        #expect(!checker.canImportUSD(atPath: "/nope/python3"))
    }
}

@Suite("BridgeError & availability")
struct BridgeErrorTests {

    @Test func errorsCarryDescriptionsAndRecovery() {
        let errors: [BridgeError] = [
            .pythonUnavailable(detail: "d"),
            .executionFailed(pythonTraceback: "t"),
            .malformedSnapshot(detail: "m"),
            .unreadableFile(path: "/p"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
        #expect(BridgeError.unreadableFile(path: "/p").errorDescription?.contains("/p") == true)
    }

    @Test func availabilityFlag() {
        #expect(BridgeAvailability.available(pythonPath: "/x").isAvailable)
        #expect(!BridgeAvailability.unavailable(reason: "no pxr").isAvailable)
    }
}

/// Process-level tests using a fake "python" (a shell script), so the
/// subprocess plumbing is exercised without needing usd-core installed.
@Suite("ProcessBridgeExecutor")
struct ProcessExecutorTests {

    private func makeFakePython(script: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("python3").path
        try ("#!/bin/sh\n" + script + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func capturesStdoutOnSuccess() async throws {
        let fake = try makeFakePython(script: #"printf '{"prims":[{"path":"/A"}]}'"#)
        let executor = ProcessBridgeExecutor(pythonPath: fake, scriptPath: "unused.py")
        let stage = try await BridgedStage.open(url: URL(fileURLWithPath: "/tmp/x.usdz"), executor: executor)
        #expect(stage.prim(at: PrimPath("/A")!) != nil)
        #expect(await executor.checkAvailability() == .available(pythonPath: fake))
    }

    @Test func nonZeroExitBecomesExecutionFailedWithStderr() async throws {
        let fake = try makeFakePython(script: "echo 'Traceback: no pxr' >&2; exit 3")
        let executor = ProcessBridgeExecutor(pythonPath: fake, scriptPath: "unused.py")
        do {
            _ = try await executor.snapshotJSON(forFileAt: URL(fileURLWithPath: "/tmp/x.usdz"))
            Issue.record("expected throw")
        } catch let error as BridgeError {
            guard case .executionFailed(let traceback) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(traceback.contains("no pxr"))
        }
        let availability = await executor.checkAvailability()
        #expect(!availability.isAvailable)
    }

    @Test func missingInterpreterBecomesPythonUnavailable() async {
        let executor = ProcessBridgeExecutor(pythonPath: "/nonexistent/python3", scriptPath: "s.py")
        do {
            _ = try await executor.snapshotJSON(forFileAt: URL(fileURLWithPath: "/tmp/x.usdz"))
            Issue.record("expected throw")
        } catch let error as BridgeError {
            guard case .pythonUnavailable = error else {
                Issue.record("wrong error: \(error)"); return
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

/// End-to-end smoke test against real usd-core — skipped automatically when
/// no interpreter with pxr is present (graceful degradation, Phase 0 exit
/// criterion still verified in CI where the runtime is fetched).
@Suite("Real usd-core integration")
struct RealBridgeIntegrationTests {

    @Test func opensRealUSDAWhenPxrAvailable() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)  // …/Packages/USDBridge/Tests/USDBridgeTests/…
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("Resources/Python/stage_snapshot.py").path
        guard let executor = ProcessBridgeExecutor(scriptPath: script),
              await executor.checkAvailability().isAvailable else {
            // No usd-core on this machine — graceful skip.
            return
        }
        let usda = """
        #usda 1.0
        (
            defaultPrim = "Car"
            metersPerUnit = 0.01
            upAxis = "Y"
        )
        def Xform "Car" {
            def Mesh "Wheel" {
                int[] faceVertexCounts = [3]
                token visibility = "invisible"
            }
            def Mesh "Antenna" (active = false) {
            }
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString).usda")
        try usda.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let stage = try await BridgedStage.open(url: url, executor: executor)
        #expect(stage.metadata.defaultPrim == "Car")
        #expect(stage.metadata.metersPerUnit == 0.01)
        let wheel = try #require(stage.prim(at: PrimPath("/Car/Wheel")!))
        #expect(wheel.typeName == "Mesh")
        #expect(wheel.visibility == .invisible)
        #expect(wheel.attribute(named: "faceVertexCounts")?.value == .intArray([3]))
        // Deactivated prims stay inspectable (PRD §5.3 Deactivate semantics).
        let antenna = try #require(stage.prim(at: PrimPath("/Car/Antenna")!))
        #expect(!antenna.isActive)
    }
}
