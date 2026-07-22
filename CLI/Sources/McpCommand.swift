import AgentMCP
import RenderKit
import Foundation
import RenderKit
import ScriptingKit
import USDBridge
import USDCore

/// `openusdz mcp <file> [--groups a,b,c] [--strictness off|warn|strict]
/// [--library DIR]` — serve the stage over the Agent MCP layer
/// (docs/AGENT_MCP_PLAN.md): typed, transactional, verification-gated
/// editing tools over JSON-RPC/stdio.
enum McpCommand {

    struct Resolution: Equatable {
        var fileURL: URL
        var groups: Set<ToolGroup>
        var strictness: ValidationStrictness
        var libraryDirectories: [URL]
        /// Serve the file directly instead of relaying to a running editor.
        /// Deterministic headless serving for tests/CI (the e2e flow gate) and
        /// scripted automation that must not attach to whatever document a
        /// developer happens to have open.
        var noRelay: Bool = false
    }

    /// Pure, testable flag parsing. Returns nil (after printing) on usage errors.
    static func resolve(arguments: [String], printError: (String) -> Void) -> Resolution? {
        var positional: [String] = []
        var groups = Set(ToolGroup.allCases)
        var strictness = ValidationStrictness.warn
        var libraries: [URL] = []
        var noRelay = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--no-relay":
                noRelay = true
                index += 1
            case "--groups":
                guard index + 1 < arguments.count else {
                    printError("error: --groups needs a comma-separated list (\(ToolGroup.allCases.map(\.rawValue).joined(separator: ",")))")
                    return nil
                }
                var parsed = Set<ToolGroup>()
                for name in arguments[index + 1].split(separator: ",") {
                    guard let group = ToolGroup(rawValue: String(name)) else {
                        printError("error: unknown tool group '\(name)'")
                        return nil
                    }
                    parsed.insert(group)
                }
                guard !parsed.isEmpty else {
                    printError("error: --groups list is empty")
                    return nil
                }
                groups = parsed
                index += 2
            case "--strictness":
                guard index + 1 < arguments.count,
                      let mode = ValidationStrictness(rawValue: arguments[index + 1])
                else {
                    printError("error: --strictness must be off, warn, or strict")
                    return nil
                }
                strictness = mode
                index += 2
            case "--library":
                guard index + 1 < arguments.count else {
                    printError("error: --library needs a directory path")
                    return nil
                }
                libraries.append(URL(fileURLWithPath: arguments[index + 1]))
                index += 2
            default:
                if argument.hasPrefix("--") {
                    printError("error: unknown option \(argument)")
                    return nil
                }
                positional.append(argument)
                index += 1
            }
        }
        guard positional.count == 1 else {
            printError("usage: openusdz mcp <file.usd[z|a|c]> [--groups a,b,c] [--strictness off|warn|strict] [--library DIR] [--no-relay]")
            return nil
        }
        return Resolution(
            fileURL: URL(fileURLWithPath: positional[0]),
            groups: groups,
            strictness: strictness,
            libraryDirectories: libraries,
            noRelay: noRelay)
    }

    // coverage:disable — composition root: opens the real Python bridge, locates usdrecord, and blocks on the stdio loop; each seam (resolve, routing via AdaptiveTransport.route, AgentMCP tools, transport line handling) is unit-tested in isolation.
    static func run(arguments: [String], printError: (String) -> Void) async -> Int32 {
        guard let resolution = resolve(arguments: arguments, printError: printError) else {
            return 2
        }
        let endpointURL = MCPActivityPaths.endpointURL()

        // Deterministic headless path: `--no-relay` serves the file in-process
        // for the whole lifetime and never attaches to a developer's open
        // document — the contract the e2e flow gate and scripted automation rely
        // on. A build failure here is a hard error (exit 1).
        if resolution.noRelay {
            guard let host = await makeInProcessHost(resolution, printError: printError) else {
                return 1
            }
            await StdioTransport.run(server: host.server)
            host.onEnd()
            return 0
        }

        // Interactive default: when the editor is running it hosts the editing
        // session against its OPEN document. Route each request to it when it is
        // reachable, else serve it in-process — re-decided PER REQUEST, so a
        // long-lived server that predates or outlives the app starts relaying the
        // moment the app is open instead of being frozen headless from launch
        // (specs/agent-live-editing.md).
        await AdaptiveTransport.run(
            endpointURL: endpointURL,
            makeInProcessServer: { await makeInProcessHost(resolution, printError: printError) })
        return 0
    }

    /// Build the headless in-process server (resident Python bridge + AgentMCP
    /// tool surface) and its teardown hook, or `nil` after printing why. Called
    /// lazily by `AdaptiveTransport` (only if a request must be served locally,
    /// so a relay-only session never opens the bridge) and eagerly by the
    /// `--no-relay` path.
    static func makeInProcessHost(
        _ resolution: Resolution, printError: (String) -> Void
    ) async -> AdaptiveTransport.InProcessHost? {
        do {
            let snapshotScript = try CLIRunner.snapshotScriptPath()
            guard let saveExecutor = ProcessBridgeExecutor(scriptPath: snapshotScript) else {
                printError("error: no Python interpreter found — run scripts/fetch-python-runtime.sh")
                return nil
            }
            // The MCP server is long-lived and opens many files (the initial
            // document plus every asset re-import), so it opens through one
            // resident interpreter instead of respawning per open. Save still
            // uses the one-shot executor (concrete type; save is infrequent).
            let serverScript = URL(fileURLWithPath: snapshotScript)
                .deletingLastPathComponent()
                .appendingPathComponent("bridge_server.py").path
            let openExecutor = PersistentBridgeExecutor(
                pythonPath: saveExecutor.pythonPath, serverScriptPath: serverScript)
            let bridged = try await BridgedStage.open(url: resolution.fileURL, executor: openExecutor)
            let session = EditSession(
                snapshot: bridged.snapshot,
                sourceURL: resolution.fileURL,
                strictness: resolution.strictness)
            session.saveExecutor = saveExecutor
            session.bridgeExecutor = openExecutor

            // No editor hosts this request, so persist the agent's reference
            // image to the hand-off file: an editor launched later picks it up on
            // start and shows it in the reference panel. Clear any stale record
            // so the panel reflects this session (specs/agent-live-editing.md).
            let referenceURL = MCPActivityPaths.referenceURL()
            ReferenceImage.remove(at: referenceURL)
            session.onReferenceImageChange = { image in
                if let image { try? image.write(to: referenceURL) }
                else { ReferenceImage.remove(at: referenceURL) }
            }

            // `render_views` renders natively by default (SceneKit/Model I/O — the
            // same Apple frameworks the app's viewport uses), so it returns real
            // pixels without `usd-core`/`usdrecord`. Storm is opt-in via
            // `DICYANIN_USDRECORD`.
            let renderer: (any RenderExecuting)? = NativeRendererSelection.make(
                environment: ProcessInfo.processInfo.environment,
                fileExists: { FileManager.default.fileExists(atPath: $0) })
            let scriptExecutor: (any ScriptExecuting)? = PythonRuntimeLocator().locate()
                .map { PythonProcessExecutor(pythonPath: $0) }

            // Push live tool-call activity to the editor app (if it's running)
            // over its socket; a graceful no-op when it isn't.
            let activitySink = SocketEventSink()
            let server = AgentMCPServer.make(
                session: session,
                configuration: AgentMCPServer.Configuration(
                    enabledGroups: resolution.groups,
                    renderer: renderer,
                    scriptExecutor: scriptExecutor,
                    libraryDirectories: resolution.libraryDirectories,
                    eventSink: activitySink))
            FileHandle.standardError.write(Data(
                "openusdz mcp: serving \(resolution.fileURL.lastPathComponent) (\(server.toolNames.count) tools) headless\n".utf8))
            return AdaptiveTransport.InProcessHost(
                server: server, onEnd: { activitySink.sessionEnd() })
        } catch {
            printError("error: \(error)")
            return nil
        }
    }
    // coverage:enable
}

/// Python-subprocess `ScriptExecuting` for AgentMCP's `run_script`.
struct PythonProcessExecutor: ScriptExecuting {
    var pythonPath: String

    // coverage:disable — spawns a real Python interpreter; ScriptRunner's manifest/argument flow is unit-tested against a stub executor in ScriptingKit and AgentMCP.
    func execute(
        scriptPath: String, arguments: [String],
        onStandardErrorLine: (@Sendable (String) -> Void)?
    ) async throws -> ScriptProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errText = String(decoding: errData, as: UTF8.self)
        if let onStandardErrorLine {
            for line in errText.split(separator: "\n") { onStandardErrorLine(String(line)) }
        }
        return ScriptProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: errText)
    }
    // coverage:enable
}
