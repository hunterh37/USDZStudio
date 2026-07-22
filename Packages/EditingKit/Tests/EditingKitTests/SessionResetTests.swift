import Testing
import Foundation
import USDCore
@testable import EditingKit

/// Covers `SessionStore.reset()` — the total sweep behind File ▸ "Reset Session":
/// it removes every session directory under `root` (active, recoverable, and
/// bare/partial alike) so a subsequent recovery scan finds nothing.
@Suite("Session reset: wipe all on-disk sessions")
struct SessionResetTests {

    private func scratchStore() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func resetRemovesActiveAndRecoverableSessions() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // A recoverable session (checkpoint + a command, sentinel present).
        let recoverable = try store.startSession(for: URL(fileURLWithPath: "/tmp/a.usda"))
        try recoverable.journal.append(.checkpoint(sourceURL: nil))
        try recoverable.journal.append(.command(label: "edit", forward: [], inverse: []))
        // A second, independent session directory (also non-empty WAL so the
        // recovery scan doesn't sweep it as stale before we reset).
        let other = try store.startSession(for: nil)
        try other.journal.append(.checkpoint(sourceURL: nil))
        #expect(store.recoverableSessions().count == 2)

        let removed = store.reset()

        #expect(removed == 2)                                  // both directories swept
        #expect(store.recoverableSessions().isEmpty)           // nothing left to restore
        // The root itself remains, ready for fresh sessions.
        let entries = try FileManager.default.contentsOfDirectory(
            at: store.root, includingPropertiesForKeys: nil)
        #expect(entries.isEmpty)
    }

    @Test func resetOnMissingRootIsANoOp() {
        // Never-created root (no session ever started): reset is a safe no-op.
        let store = scratchStore()
        #expect(store.reset() == 0)
        #expect(store.recoverableSessions().isEmpty)
    }
}
