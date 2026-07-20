import Foundation

/// Newline-delimited JSON-RPC over stdio — the MCP stdio transport
/// (docs/AGENT_MCP_PLAN.md §7: "stdio first (works everywhere today)";
/// the adapter is transport-swappable so an in-process streamable-HTTP
/// server can ship later without touching tool code).
public enum StdioTransport {

    /// Process one input line; returns the serialized response line, or
    /// `nil` for notifications / blank lines. Pure and unit-testable.
    public static func respond(toLine line: String, server: MCPServer) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let response = await server.handle(data: Data(trimmed.utf8)) else { return nil }
        return response.serializedString
    }

    // coverage:disable — blocking stdin/stdout run loop: exercised by driving the real executable, not in-process unit tests. Line handling is covered via respond(toLine:server:).
    /// Blocking run loop: read stdin line-by-line until EOF, write one
    /// response line per request to stdout.
    public static func run(server: MCPServer) async {
        while let line = readLine(strippingNewline: true) {
            if let out = await respond(toLine: line, server: server) {
                FileHandle.standardOutput.write(Data((out + "\n").utf8))
            }
        }
    }
    // coverage:enable
}
