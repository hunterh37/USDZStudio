import AgentMCP
import Foundation
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
    }

    /// Pure, testable flag parsing. Returns nil (after printing) on usage errors.
    static func resolve(arguments: [String], printError: (String) -> Void) -> Resolution? {
        var positional: [String] = []
        var groups = Set(ToolGroup.allCases)
        var strictness = ValidationStrictness.warn
        var libraries: [URL] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
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
            printError("usage: openusdz mcp <file.usd[z|a|c]> [--groups a,b,c] [--strictness off|warn|strict] [--library DIR]")
            return nil
        }
        return Resolution(
            fileURL: URL(fileURLWithPath: positional[0]),
            groups: groups,
            strictness: strictness,
            libraryDirectories: libraries)
    }

    // coverage:disable — composition root: opens the real Python bridge, locates usdrecord, and blocks on the stdio loop; each seam (resolve, AgentMCP tools, transport line handling) is unit-tested in isolation.
    static func run(arguments: [String], printError: (String) -> Void) async -> Int32 {
        guard let resolution = resolve(arguments: arguments, printError: printError) else {
            return 2
        }
        // If the editor app is running, it hosts the editing session against its
        // OPEN document — become a thin stdin↔socket↔stdout pump so the agent
        // edits (and the user watches) the live viewport (specs/agent-live-editing.md).
        let endpointURL = MCPActivityPaths.endpointURL()
        if let pump = RelayPump.make(endpointURL: endpointURL) {
            FileHandle.standardError.write(Data(
                "openusdz mcp: editor is live — relaying to the open document\n".utf8))
            return await pump.run()
        }
        do {
            let snapshotScript = try CLIRunner.snapshotScriptPath()
            guard let saveExecutor = ProcessBridgeExecutor(scriptPath: snapshotScript) else {
                printError("error: no Python interpreter found — run scripts/fetch-python-runtime.sh")
                return 1
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

            let locator = PythonRuntimeLocator()
            // `render_views` renders natively by default (SceneKit/Model I/O — the
            // same Apple frameworks the app's viewport uses), so it returns real
            // pixels out of the box without `usd-core`/`usdrecord`. Storm is strictly
            // opt-in via `DICYANIN_USDRECORD`: auto-detecting a `usdrecord` beside the
            // interpreter used to win silently and, when that binary was a stub
            // without imaging support (e.g. the one shipped by the `usd-core` wheel
            // or system Python), it failed every render instead of falling back.
            let renderer: (any RenderExecuting)? = NativeRendererSelection.make(
                environment: ProcessInfo.processInfo.environment,
                fileExists: { FileManager.default.fileExists(atPath: $0) })

            let scriptExecutor: (any ScriptExecuting)? = locator.locate()
                .map { PythonProcessExecutor(pythonPath: $0) }

            // Push live tool-call activity to the editor app (if it's running)
            // over its localhost socket; a graceful no-op when it isn't.
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
                "openusdz mcp: serving \(resolution.fileURL.lastPathComponent) (\(server.toolNames.count) tools) over stdio\n".utf8))
            await StdioTransport.run(server: server)
            activitySink.sessionEnd()
            return 0
        } catch {
            printError("error: \(error)")
            return 1
        }
    }
    // coverage:enable
}

/// `usdrecord`-backed renderer for AgentMCP's `render_views`.
struct UsdrecordRenderer: RenderExecuting {
    var usdrecordPath: String

    // coverage:disable — spawns the real usdrecord binary; the render tool's stage/camera authoring is unit-tested against a stub renderer.
    func render(stageURL: URL, outputURL: URL, cameraPath: String, size: Int) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: usdrecordPath)
        process.arguments = [
            "--imageWidth", String(size),
            "--camera", cameraPath,
            stageURL.path, outputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.pythonUnavailable(detail: "usdrecord exited \(process.terminationStatus)")
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
