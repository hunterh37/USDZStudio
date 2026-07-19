import Testing
import Foundation
@testable import ScriptingKit

@Suite("ScriptProgress")
struct ScriptProgressTests {

    @Test func parsesHarnessProgressLine() throws {
        let p = try #require(ScriptProgress.parse(line: "[ 50%] Decimating…"))
        #expect(p.fraction == 0.5)
        #expect(p.message == "Decimating…")
    }

    @Test func parsesZeroAndHundred() throws {
        #expect(ScriptProgress.parse(line: "[  0%] start")?.fraction == 0)
        #expect(ScriptProgress.parse(line: "[100%] done")?.fraction == 1)
    }

    @Test func clampsOutOfRangePercent() throws {
        #expect(ScriptProgress.parse(line: "[150%] over")?.fraction == 1)
    }

    @Test func toleratesNoMessage() throws {
        let p = try #require(ScriptProgress.parse(line: "[ 25%]"))
        #expect(p.message.isEmpty)
        #expect(p.fraction == 0.25)
    }

    @Test func rejectsNonProgressLines() {
        #expect(ScriptProgress.parse(line: "saved in place: /tmp/x.usda") == nil)
        #expect(ScriptProgress.parse(line: "[oops] not a percent") == nil)
        #expect(ScriptProgress.parse(line: "[] empty") == nil)
        #expect(ScriptProgress.parse(line: "") == nil)
        #expect(ScriptProgress.parse(line: "just text") == nil)
    }

    @Test func classifyRoutesLines() {
        if case .progress(let p) = ScriptRunEvent.classify(line: "[ 10%] go") {
            #expect(p.fraction == 0.1)
        } else {
            Issue.record("expected progress event")
        }
        if case .log(let line) = ScriptRunEvent.classify(line: "hello") {
            #expect(line == "hello")
        } else {
            Issue.record("expected log event")
        }
    }
}
