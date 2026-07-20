import Foundation
import EditingKit
import Testing
import USDCore
@testable import AgentMCP

/// The `sharing:` initializer binds a session to an existing stage + stack, so
/// the app can host tools directly on its open document (specs/agent-live-editing.md).
@Suite struct SharedSessionTests {

    @Test func sharesStageAndStackWithHost() throws {
        // The "host" (stand-in for EditorDocument) owns a stage + stack.
        let stage = InMemoryStage(Fixtures.snapshot())
        let stack = CommandStack(stage: stage)

        // A session bound with `sharing:` uses the very same instances.
        let session = EditSession(sharing: stage, stack: stack)
        #expect(session.stage === stage)
        #expect(session.stack === stack)

        // A mutation through the session lands on the shared stack (so the
        // host's onChange/refresh would fire) and is visible on the shared stage.
        let path = PrimPath("/Root/Extra")!
        let insert = InsertPrimCommand(
            prim: Prim(path: path, typeName: "Xform"),
            parent: PrimPath("/Root")!, index: 0)
        let outcome = try session.mutate(insert)
        #expect(outcome.undoToken == stack.undoCount)
        #expect(stage.prim(at: path) != nil)

        // Conversely, a command run directly on the shared stack is visible
        // through the session's stage — one source of truth.
        let path2 = PrimPath("/Root/Extra2")!
        _ = try stack.run(InsertPrimCommand(
            prim: Prim(path: path2, typeName: "Xform"),
            parent: PrimPath("/Root")!, index: 0))
        #expect(session.stage.prim(at: path2) != nil)
    }
}
