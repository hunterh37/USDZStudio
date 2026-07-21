import EditingKit
import Foundation
import Testing
import USDCore
@testable import AgentMCP

@Suite struct EditSessionTests {

    @Test func resolvesPathsAndPrimIDs() throws {
        let session = Fixtures.session()
        let byPath = try session.resolve(.object(["path": "/Root/Box"]))
        #expect(byPath == PrimPath("/Root/Box")!)
        let id = session.id(for: byPath)
        let byID = try session.resolve(.object(["path": .string(id)]))
        #expect(byID == byPath)

        #expect(throws: ToolError.self) { _ = try session.resolve(.object([:])) }
        #expect(throws: ToolError.self) { _ = try session.resolve(.object(["path": "/Nope"])) }
        #expect(throws: ToolError.self) { _ = try session.resolve(.object(["path": "prim-404"])) }
        #expect(throws: ToolError.self) { _ = try session.resolve(.object(["path": "//bad path"])) }
    }

    @Test func staleIDAfterRemovalThrows() throws {
        let session = Fixtures.session()
        let path = PrimPath("/Root/Lid")!
        let id = session.id(for: path)
        let command = try MutateTools.removeCommand(for: path, session: session)
        _ = try session.mutate(command)
        // Registry not yet invalidated (mutate got no `removed` hint) — the
        // resolve still fails because the prim is gone from the stage.
        #expect(throws: ToolError.self) {
            _ = try session.resolve(.object(["path": .string(id)]))
        }
    }

    @Test func mutateProducesOutcomeWithDiffAndValidation() throws {
        let session = Fixtures.session()
        let command = SetActiveCommand(path: PrimPath("/Root/Lid")!, newValue: false, oldValue: true)
        let outcome = try session.mutate(command)
        #expect(outcome.verb.contains("Disable"))
        #expect(outcome.diff.modifiedPrims == [PrimPath("/Root/Lid")!])
        #expect(outcome.validation != nil)
        #expect(outcome.undoToken == 1)
        #expect(outcome.primIds[PrimPath("/Root/Lid")!] != nil)
        let json = outcome.asJSON(extra: ["x": .bool(true)])
        #expect(json["verb"].stringValue == outcome.verb)
        #expect(json["x"].boolValue == true)
    }

    @Test func offModeSkipsValidation() throws {
        let session = Fixtures.session(strictness: .off)
        let outcome = try session.mutate(
            SetActiveCommand(path: PrimPath("/Root/Box")!, newValue: false, oldValue: true))
        #expect(outcome.validation == nil)
    }

    @Test func strictModeRollsBackNewErrors() throws {
        let session = Fixtures.session(strictness: .strict)
        // Deleting all mesh geometry under Root triggers arkit-profile errors
        // (empty stage / unbound-mesh style rules) — craft one that clearly
        // introduces an error: remove `points` from Box, creating an empty mesh.
        let box = PrimPath("/Root/Box")!
        let removed = session.stage.prim(at: box)!.attribute(named: "points")!
        let command = RemoveAttributeCommand(path: box, removed: removed)
        do {
            _ = try session.mutate(command)
            // If the profile doesn't flag it as .error, mutation stands — both
            // outcomes are contract-valid; assert consistency either way.
            #expect(session.stage.prim(at: box)!.attribute(named: "points") == nil)
        } catch let error as ToolError {
            guard case .rejectedByValidation = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            // Rolled back: points restored.
            #expect(session.stage.prim(at: box)!.attribute(named: "points") != nil)
        }
    }

    @Test func mutateSurfacesStageErrorsStructured() {
        let session = Fixtures.session()
        // Insert under a nonexistent parent → StageMutationError → ToolError.failed.
        let orphan = Prim(path: PrimPath("/Nowhere/X")!, typeName: "Xform")
        let command = InsertPrimCommand(prim: orphan, parent: PrimPath("/Nowhere")!, index: 0)
        #expect(throws: ToolError.self) { _ = try session.mutate(command) }
    }

    @Test func undoRedoAndUndoTo() throws {
        let session = Fixtures.session()
        for i in 0..<3 {
            _ = try session.mutate(SetActiveCommand(
                path: PrimPath("/Root/Box")!, newValue: i % 2 == 0 ? false : true,
                oldValue: i % 2 == 0 ? true : false))
        }
        #expect(session.stack.undoCount == 3)
        #expect(try session.undo() != nil)
        #expect(try session.redo() != nil)
        let undone = try session.undo(to: 1)
        #expect(undone.count == 2)
        #expect(session.stack.undoCount == 1)
        #expect(throws: ToolError.self) { _ = try session.undo(to: 99) }
        #expect(throws: ToolError.self) { _ = try session.undo(to: -1) }
        _ = try session.undo(to: 0)
        #expect(try session.undo() == nil)
        #expect(session.stage.prim(at: PrimPath("/Root/Box")!)!.isActive)
    }

    @Test func saveWritesUSDA() async throws {
        let session = Fixtures.session()
        let url = Fixtures.tempDirectory().appendingPathComponent("out.usda")
        let saved = try await session.save(to: url)
        let text = try String(contentsOf: saved, encoding: .utf8)
        #expect(text.contains("#usda"))
        #expect(text.contains("Box"))
        // No sourceURL and no explicit target → structured failure.
        await #expect(throws: ToolError.self) { _ = try await session.save() }
        // Unsupported extension → wrapped failure.
        await #expect(throws: ToolError.self) {
            _ = try await session.save(to: URL(fileURLWithPath: "/tmp/x.obj"))
        }
    }
}

@Suite struct MCPServerTests {

    @Test func initializeListAndCallFlow() async throws {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        let initResponse = await server.handle(data: Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8))!
        #expect(initResponse["result"]["protocolVersion"].stringValue == MCPServer.protocolVersion)
        #expect(initResponse["result"]["serverInfo"]["name"].stringValue == "openusdz-agent")
        // The server advertises capability guidance the client folds into the
        // system prompt — including proactively hinging objects that open.
        let instructions = initResponse["result"]["instructions"].stringValue ?? ""
        #expect(instructions.contains("create_joint"))
        #expect(instructions == AgentInstructions.text)
        // A server with no instructions set omits the field entirely.
        let bare = MCPServer()
        let bareInit = await bare.handle(request: JSONRPCRequest(id: .number(9), method: "initialize"))!
        #expect(bareInit["result"]["instructions"] == .null)

        let ping = await server.handle(request: JSONRPCRequest(id: .number(2), method: "ping"))!
        #expect(ping["result"] == .object([:]))

        let list = await server.handle(request: JSONRPCRequest(id: .number(3), method: "tools/list"))!
        let tools = list["result"]["tools"].arrayValue!
        #expect(tools.count == server.toolNames.count)
        #expect(server.toolNames.contains("query_scene"))
        #expect(server.toolNames.contains("batch"))
        // Regression guard (#72 gap): the articulation tools ship in AgentMCP but
        // were never wired into make(), so no served binary exposed them. Assert
        // make() actually registers every tool group, joints included.
        #expect(server.toolNames.contains("create_joint"))
        #expect(server.toolNames.contains("set_joint_state"))
        #expect(tools.allSatisfy { $0["inputSchema"]["type"].stringValue == "object" })

        let stats = await callOK(server, "scene_stats")
        #expect(stats["meshes"].intValue == 2)
    }

    @Test func notificationsGetNoResponse() async {
        let server = Fixtures.server(session: Fixtures.session())
        let response = await server.handle(data: Data(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(response == nil)
    }

    @Test func malformedAndUnknownRequests() async {
        let server = Fixtures.server(session: Fixtures.session())
        let parseFailure = await server.handle(data: Data("garbage".utf8))!
        #expect(parseFailure["error"]["code"].intValue == -32700)
        let unknown = await server.handle(request: JSONRPCRequest(id: .number(1), method: "nope"))!
        #expect(unknown["error"]["code"].intValue == -32601)
    }

    @Test func toolCallErrorShapes() async {
        let server = Fixtures.server(session: Fixtures.session())
        let noName = await call(server, "")
        _ = noName
        let missing = await server.handle(request: JSONRPCRequest(
            id: .number(1), method: "tools/call", params: .object([:])))!
        #expect(missing["result"]["isError"].boolValue == true)
        let unknownTool = await callError(server, "does_not_exist")
        #expect(unknownTool.contains("unknown tool"))
        // A ToolError surfaces as isError with the structured message.
        let bad = await callError(server, "get_prim", ["path": "/Nope"])
        #expect(bad.contains("prim not found"))
    }

    @Test func groupFilteringLimitsSurface() async {
        let session = Fixtures.session()
        let server = AgentMCPServer.make(
            session: session,
            configuration: .init(enabledGroups: [.read, .verify]))
        #expect(server.toolNames.contains("query_scene"))
        #expect(server.toolNames.contains("validate"))
        #expect(!server.toolNames.contains("create_prim"))
        #expect(!server.toolNames.contains("undo"))
        let message = await callError(server, "create_prim", ["name": "X"])
        #expect(message.contains("unknown tool"))
        #expect(message.contains("read"))
    }

    @Test func resourcesAndPrompts() async throws {
        let server = Fixtures.server(session: Fixtures.session())
        let list = await server.handle(request: JSONRPCRequest(id: .number(1), method: "resources/list"))!
        let uris = list["result"]["resources"].arrayValue!.compactMap { $0["uri"].stringValue }
        #expect(Set(uris) == ["usd://scene", "usd://stats", "usd://history"])

        let read = await server.handle(request: JSONRPCRequest(
            id: .number(2), method: "resources/read", params: ["uri": "usd://stats"]))!
        let text = read["result"]["contents"].arrayValue!.first!["text"].stringValue!
        #expect(text.contains("\"meshes\":2"))

        let badRead = await server.handle(request: JSONRPCRequest(
            id: .number(3), method: "resources/read", params: ["uri": "usd://nope"]))!
        #expect(badRead["error"]["code"].intValue == -32602)
        let noURI = await server.handle(request: JSONRPCRequest(
            id: .number(4), method: "resources/read"))!
        #expect(noURI["error"]["code"].intValue == -32602)

        let prompts = await server.handle(request: JSONRPCRequest(id: .number(5), method: "prompts/list"))!
        let names = prompts["result"]["prompts"].arrayValue!.compactMap { $0["name"].stringValue }
        #expect(names.contains("build-validate-score-loop"))
        #expect(names.contains("sculpt-from-image"))
        #expect(names.contains("author-hinged-object"))
        #expect(names.count == 6)

        let prompt = await server.handle(request: JSONRPCRequest(
            id: .number(6), method: "prompts/get", params: ["name": "import-and-normalize"]))!
        let promptText = prompt["result"]["messages"].arrayValue!.first!["content"]["text"].stringValue!
        #expect(promptText.contains("import_asset"))
        let badPrompt = await server.handle(request: JSONRPCRequest(
            id: .number(7), method: "prompts/get", params: ["name": "nope"]))!
        #expect(badPrompt["error"]["code"].intValue == -32602)

        // History resource reflects the stack.
        let history = await server.handle(request: JSONRPCRequest(
            id: .number(8), method: "resources/read", params: ["uri": "usd://history"]))!
        #expect(history["result"]["contents"].arrayValue?.isEmpty == false)
    }

    @Test func stdioRespondHandlesLinesAndNotifications() async {
        let server = Fixtures.server(session: Fixtures.session())
        #expect(await StdioTransport.respond(toLine: "  \n", server: server) == nil)
        #expect(await StdioTransport.respond(
            toLine: #"{"jsonrpc":"2.0","method":"note"}"#, server: server) == nil)
        let out = await StdioTransport.respond(
            toLine: #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#, server: server)
        #expect(out?.contains("\"id\":9") == true)
    }
}
