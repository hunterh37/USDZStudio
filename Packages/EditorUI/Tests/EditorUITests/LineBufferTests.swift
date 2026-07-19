import Testing
@testable import EditorUI

@Suite("LineBuffer")
struct LineBufferTests {

    @Test func emitsCompleteLinesOnly() {
        var buffer = LineBuffer()
        #expect(buffer.append("hello\nwor") == ["hello"])
        #expect(buffer.append("ld\n") == ["world"])
        #expect(buffer.flush() == nil)
    }

    @Test func buffersPartialLineAcrossChunks() {
        var buffer = LineBuffer()
        #expect(buffer.append("[ 5") == [])
        #expect(buffer.append("0%] half") == [])
        #expect(buffer.append("\n") == ["[ 50%] half"])
    }

    @Test func flushReturnsTrailingPartial() {
        var buffer = LineBuffer()
        _ = buffer.append("done\ntail without newline")
        #expect(buffer.flush() == "tail without newline")
        #expect(buffer.flush() == nil)     // idempotent after flush
    }

    @Test func handlesMultipleLinesInOneChunk() {
        var buffer = LineBuffer()
        #expect(buffer.append("a\nb\nc\n") == ["a", "b", "c"])
    }
}
