import Testing
import Foundation
@testable import ScriptingKit

@Suite("ScriptLibrary")
struct ScriptLibraryTests {

    @Test func filtersToPythonFiles() {
        let urls = [URL(fileURLWithPath: "/s/a.py"), URL(fileURLWithPath: "/s/b.txt"),
                    URL(fileURLWithPath: "/s/c.PY")]
        let entries = ScriptLibrary.scripts(from: urls, bundled: false)
        #expect(entries.map(\.displayName) == ["a", "c"])
        #expect(entries.allSatisfy { !$0.isBundled })
    }

    @Test func sortsBundledFirstThenAlphabetical() {
        let entries = [
            ScriptEntry(url: URL(fileURLWithPath: "/u/zeta.py"), isBundled: false),
            ScriptEntry(url: URL(fileURLWithPath: "/b/Batch.py"), isBundled: true),
            ScriptEntry(url: URL(fileURLWithPath: "/u/alpha.py"), isBundled: false),
            ScriptEntry(url: URL(fileURLWithPath: "/b/anchor.py"), isBundled: true),
        ]
        let sorted = ScriptLibrary.sorted(entries)
        #expect(sorted.map(\.displayName) == ["anchor", "Batch", "alpha", "zeta"])
    }

    @Test func identityAndNames() {
        let entry = ScriptEntry(url: URL(fileURLWithPath: "/x/decimate.py"), isBundled: true)
        #expect(entry.id == "/x/decimate.py")
        #expect(entry.displayName == "decimate")
    }
}
