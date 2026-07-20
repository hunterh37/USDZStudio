import Foundation
import USDCore

/// §3.6 Transaction control — the ecosystem's weakest area, ours for free
/// via `CommandStack`.
public enum TransactionTools {

    public static func register(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "undo", group: .transaction,
            description: "Undo the most recent mutation. Returns the undone verb.",
            inputSchema: Schema.object([:])
        ) { _ in
            guard let verb = try session.undo() else {
                return .object(["undone": .null, "note": "nothing to undo"])
            }
            return .object(["undone": .string(verb), "undoToken": .number(Double(session.stack.undoCount))])
        })

        server.register(MCPTool(
            name: "redo", group: .transaction,
            description: "Redo the most recently undone mutation.",
            inputSchema: Schema.object([:])
        ) { _ in
            guard let verb = try session.redo() else {
                return .object(["redone": .null, "note": "nothing to redo"])
            }
            return .object(["redone": .string(verb), "undoToken": .number(Double(session.stack.undoCount))])
        })

        server.register(MCPTool(
            name: "undo_to", group: .transaction,
            description: "Roll back to a prior undoToken (as returned by a mutating tool). Undoes every step after it.",
            inputSchema: Schema.object([
                "token": Schema.integer("target undoToken")
            ], required: ["token"])
        ) { args in
            guard let token = args["token"].intValue else {
                throw ToolError.invalidParams("'token' must be an integer")
            }
            let undone = try session.undo(to: token)
            return .object([
                "undone": .array(undone.map { .string($0) }),
                "undoToken": .number(Double(session.stack.undoCount)),
            ])
        })

        server.register(MCPTool(
            name: "save", group: .transaction,
            description: "Save the stage to its source file, or to 'url' (usda always; usd/usdc/usdz need the Python bridge).",
            inputSchema: Schema.object([
                "url": Schema.string("destination file path (optional)")
            ])
        ) { args in
            let target = args["url"].stringValue.map { URL(fileURLWithPath: $0) }
            let saved = try await session.save(to: target)
            return .object(["saved": .string(saved.path)])
        })
    }
}
