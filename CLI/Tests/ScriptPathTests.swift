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
