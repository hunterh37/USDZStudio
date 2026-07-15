import Testing
import Foundation
import USDBridge
@testable import dicyanin_usdz

@Suite("snapshotScriptPath resolution")
struct ScriptPathTests {

    @Test func environmentOverrideWins() throws {
        let path = try CLIRunner.snapshotScriptPath(
            environment: ["DICYANIN_SNAPSHOT_SCRIPT": "/custom/snap.py"],
            startingAt: "/nowhere")
        #expect(path == "/custom/snap.py")
    }

    @Test func emptyOverrideIsIgnoredAndSearchFailsCleanly() {
        #expect(throws: BridgeError.self) {
            _ = try CLIRunner.snapshotScriptPath(
                environment: ["DICYANIN_SNAPSHOT_SCRIPT": ""],
                startingAt: "/nonexistent/deep/path")
        }
    }

    @Test func walksUpToFindRepoScript() throws {
        // Build a fake repo: root/Resources/Python/stage_snapshot.py, start 2 levels down.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-test-\(UUID().uuidString)")
        let scriptDir = root.appendingPathComponent("Resources/Python")
        let startDir = root.appendingPathComponent("CLI/.build")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: startDir, withIntermediateDirectories: true)
        let script = scriptDir.appendingPathComponent("stage_snapshot.py")
        try "print('hi')".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let found = try CLIRunner.snapshotScriptPath(environment: [:], startingAt: startDir.path)
        #expect(found == script.path)
    }
}

@Suite("scriptsDirectoryPath resolution")
struct ScriptsDirPathTests {

    @Test func environmentOverrideWins() throws {
        let path = try CLIRunner.scriptsDirectoryPath(
            environment: ["DICYANIN_SCRIPTS_DIR": "/custom/scripts"],
            startingAt: "/nowhere")
        #expect(path == "/custom/scripts")
    }

    @Test func walksUpToFindScriptsDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-scripts-\(UUID().uuidString)")
        let scriptsDir = root.appendingPathComponent("Resources/Python/scripts")
        let startDir = root.appendingPathComponent("CLI/.build")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: startDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let found = try CLIRunner.scriptsDirectoryPath(environment: [:], startingAt: startDir.path)
        #expect(found == scriptsDir.path)
    }

    @Test func missingScriptsDirThrows() {
        #expect(throws: BridgeError.self) {
            _ = try CLIRunner.scriptsDirectoryPath(
                environment: [:], startingAt: "/nonexistent/deep/path")
        }
    }
}

@Suite("run command resolution")
struct RunResolutionTests {

    private func resolve(
        _ args: [String],
        python: String? = "/usr/bin/python3",
        exists: @escaping (String) -> Bool,
        scriptsDir: String? = nil
    ) -> (CLIRunner.RunResolution, [String]) {
        var err: [String] = []
        let result = CLIRunner.resolveRun(
            arguments: args,
            locatePython: { python },
            fileExists: exists,
            bundledScriptsDir: { scriptsDir },
            printError: { err.append($0) })
        return (result, err)
    }

    @Test func tooFewArgumentsIsUsageError() {
        let (result, err) = resolve(["only_script.py"], exists: { _ in true })
        #expect(result == .fail(2))
        #expect(err.first?.contains("run needs a script") == true)
    }

    @Test func resolvesExplicitScriptPath() {
        let (result, _) = resolve(
            ["/abs/thing.py", "model.usdz"],
            exists: { $0 == "/abs/thing.py" })
        guard case .invocation(let inv) = result else { return #expect(Bool(false)) }
        #expect(inv.python == "/usr/bin/python3")
        #expect(inv.arguments == ["/abs/thing.py", "model.usdz"])
        #expect(inv.pythonPath == ["/abs"])
    }

    @Test func appendsDotPyWhenMissing() {
        let (result, _) = resolve(
            ["/abs/thing", "model.usdz"],
            exists: { $0 == "/abs/thing.py" })
        guard case .invocation(let inv) = result else { return #expect(Bool(false)) }
        #expect(inv.arguments.first == "/abs/thing.py")
    }

    @Test func resolvesBundledScriptByBareName() {
        let (result, _) = resolve(
            ["texture_report", "model.usdz", "--json"],
            exists: { $0 == "/bundled/texture_report.py" },
            scriptsDir: "/bundled")
        guard case .invocation(let inv) = result else { return #expect(Bool(false)) }
        #expect(inv.arguments == ["/bundled/texture_report.py", "model.usdz", "--json"])
        #expect(inv.pythonPath == ["/bundled"])
    }

    @Test func scriptFlagsPassThrough() {
        let (result, _) = resolve(
            ["/s/x.py", "m.usdz", "--frame", "3", "--dry-run"],
            exists: { _ in true })
        guard case .invocation(let inv) = result else { return #expect(Bool(false)) }
        #expect(inv.arguments == ["/s/x.py", "m.usdz", "--frame", "3", "--dry-run"])
    }

    @Test func unknownScriptIsUsageError() {
        let (result, err) = resolve(
            ["nope", "model.usdz"], exists: { _ in false }, scriptsDir: "/bundled")
        #expect(result == .fail(2))
        #expect(err.first?.contains("script not found") == true)
    }

    @Test func missingPythonIsRuntimeError() {
        let (result, err) = resolve(
            ["/s/x.py", "m.usdz"], python: nil, exists: { _ in true })
        #expect(result == .fail(1))
        #expect(err.first?.contains("no Python interpreter") == true)
    }
}
