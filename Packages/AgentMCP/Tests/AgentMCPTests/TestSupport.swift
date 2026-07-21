import Foundation
import MeshKit
import Testing
import USDCore
@testable import AgentMCP

/// Shared fixtures: a small scene with real mesh geometry, and helpers for
/// driving tools through the full MCP dispatch path.
enum Fixtures {

    /// `/Root` (Xform) containing a unit box at origin and a second box
    /// translated up — enough geometry for bbox/raycast/solver/mesh tests.
    static func snapshot() -> StageSnapshot {
        let boxFlat = MeshIO.flat(from: try! Primitives.box())
        let box = Prim(
            path: PrimPath("/Root/Box")!,
            typeName: "Mesh",
            attributes: GeometryProbe.meshAttributes(from: boxFlat))
        var lidAttributes = GeometryProbe.meshAttributes(from: boxFlat)
        lidAttributes.append(Attribute(
            name: "xformOp:transform",
            value: .matrix4([
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 3, 0, 1,
            ])))
        let lid = Prim(
            path: PrimPath("/Root/Lid")!,
            typeName: "Mesh",
            attributes: lidAttributes)
        let root = Prim(
            path: PrimPath("/Root")!, typeName: "Xform", children: [box, lid])
        return StageSnapshot(
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: "Root"),
            rootPrims: [root])
    }

    static func session(strictness: ValidationStrictness = .warn) -> EditSession {
        EditSession(snapshot: snapshot(), strictness: strictness)
    }

    /// A session whose stage starts empty (no `/Root`), so sculpt passes author
    /// the *only* geometry present — used by the AR-compliance completion-gate
    /// tests where the finished stage must be judged on the sculpt output alone.
    static func emptySession(strictness: ValidationStrictness = .warn) -> EditSession {
        let snapshot = StageSnapshot(
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: nil),
            rootPrims: [])
        return EditSession(snapshot: snapshot, strictness: strictness)
    }

    /// An empty stage whose `defaultPrim` names a prim that does not exist — a
    /// hard AR-compliance error (DefaultPrimRule) that never resolves, so the
    /// AR-compliance completion gate must block. Strictness `.warn` so the bad
    /// metadata doesn't trip the session's own mutation guard.
    static func nonCompliantSession() -> EditSession {
        let snapshot = StageSnapshot(
            metadata: StageMetadata(upAxis: .y, metersPerUnit: 1.0, defaultPrim: "Ghost"),
            rootPrims: [])
        return EditSession(snapshot: snapshot, strictness: .warn)
    }

    static func server(
        session: EditSession,
        configuration: AgentMCPServer.Configuration? = nil
    ) -> MCPServer {
        // Default to a unique per-server work directory so persisted sculpt
        // state (spec/assessment/orchestrator) never leaks between tests —
        // mirroring production, where each project has its own work directory.
        let configuration = configuration ?? .init(workDirectory: tempDirectory())
        return AgentMCPServer.make(session: session, configuration: configuration)
    }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmcp-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Drive one tool through tools/call and return `structuredContent`
/// (or the error payload when `isError`).
func call(_ server: MCPServer, _ name: String, _ args: JSONValue = .object([:])) async -> JSONValue {
    let request = JSONRPCRequest(
        id: .number(1), method: "tools/call",
        params: .object(["name": .string(name), "arguments": args]))
    let response = await server.handle(request: request)!
    return response["result"]
}

/// Structured result of a successful tool call; traps on tool error.
func callOK(_ server: MCPServer, _ name: String, _ args: JSONValue = .object([:]),
            sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
    let result = await call(server, name, args)
    #expect(result["isError"].boolValue == false,
            "\(name) failed: \(result.serializedString)",
            sourceLocation: sourceLocation)
    return result["structuredContent"]
}

/// Error text of a failing tool call; traps on success.
func callError(_ server: MCPServer, _ name: String, _ args: JSONValue = .object([:]),
               sourceLocation: SourceLocation = #_sourceLocation) async -> String {
    let result = await call(server, name, args)
    #expect(result["isError"].boolValue == true,
            "\(name) unexpectedly succeeded", sourceLocation: sourceLocation)
    return result["content"].arrayValue?.first?["text"].stringValue ?? ""
}
