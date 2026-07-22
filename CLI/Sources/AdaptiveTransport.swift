import AgentMCP
import Foundation

/// Per-request routing between the **live editor** (relay to the open document)
/// and a **headless in-process server** (specs/agent-live-editing.md).
///
/// The relay-vs-headless choice used to be made once, in `McpCommand.run`, from
/// a ~2.5 s window at startup: no editor then → serve headless for the entire
/// process lifetime, with no path back. But Claude Code spawns **one**
/// `openusdz mcp` server per session and keeps it alive for hours while the user
/// opens and closes the app repeatedly, so a server that started before the app
/// (or outlived a previous window) stayed frozen headless — agent edits landed
/// in an orphaned stage the viewport never showed.
///
/// This transport instead re-decides on **every** JSON-RPC line: if a live
/// editor endpoint is reachable right now, the request relays to it (and the
/// user watches the viewport update); otherwise it is served in-process. The
/// server's dispatch is stateless across the `initialize` handshake, so routing
/// different requests to different handlers mid-session is safe.
enum AdaptiveTransport {

    /// A lazily-built headless server plus its teardown hook. Built only when a
    /// request must actually be served in-process, so a relay-only session never
    /// opens the Python bridge (and needs no `usd-core` runtime).
    struct InProcessHost {
        let server: MCPServer
        let onEnd: () -> Void
    }

    enum Route: Equatable { case relay, inProcess }

    /// Pure routing decision: a reachable editor wins, else serve in-process.
    /// (`--no-relay` never reaches here — `McpCommand` pins that path headless.)
    static func route(editorLive: Bool) -> Route {
        editorLive ? .relay : .inProcess
    }

    // coverage:disable — blocking stdin/stdout loop over a live AF_UNIX socket
    // and the Python bridge; the routing decision (`route`) and the single-line
    // handlers it drives (`RelayPump.relayLine`, `StdioTransport.respond`) are
    // unit-tested. Exercised end-to-end by the agent-live recipe.
    /// Read stdin line-by-line until EOF, routing each request per the live
    /// endpoint. Writes exactly one response line per request that owes one.
    static func run(
        endpointURL: URL,
        makeInProcessServer: () async -> InProcessHost?
    ) async {
        let pump = RelayPump(endpointURL: endpointURL)
        var host: InProcessHost?
        var lastRoute: Route?

        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }

            let route = route(editorLive: RelayPump.liveEndpoint(at: endpointURL) != nil)
            if route != lastRoute {
                announce(route)
                lastRoute = route
            }

            let output: String?
            switch route {
            case .relay:
                output = await pump.relayLine(line)
            case .inProcess:
                if host == nil { host = await makeInProcessServer() }
                if let host {
                    output = await StdioTransport.respond(toLine: line, server: host.server)
                } else {
                    // The runtime is missing and the request must be served
                    // locally — surface a correctable error, never a silent hang.
                    output = RelayCodec.isNotification(line) ? nil
                        : RelayCodec.errorResponse(
                            idFragment: RelayCodec.jsonrpcIDFragment(line),
                            code: -32002,
                            message: "no Python runtime and no live editor — run scripts/fetch-python-runtime.sh or open the app")
                }
            }

            if let output, !output.isEmpty {
                FileHandle.standardOutput.write(Data((output + "\n").utf8))
            }
        }

        pump.shutdown()
        host?.onEnd()
    }

    /// One stderr line whenever the route flips, so the transition an agent or
    /// user is debugging ("why did it stop showing in the app?") is visible.
    private static func announce(_ route: Route) {
        let message = route == .relay
            ? "openusdz mcp: editor is live — relaying to the open document\n"
            : "openusdz mcp: no editor running — serving headless\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
    // coverage:enable
}
