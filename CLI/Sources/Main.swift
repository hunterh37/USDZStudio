import Foundation
import USDCore
import USDBridge

/// Phase 0 CLI: `dicyanin-usdz info <file>` prints the prim tree.
/// `convert`, `validate`, `run` subcommands arrive in Phases 2/4
/// (specs/scripting.md). Exit codes: 0 ok, 1 runtime failure, 2 usage.
@main
struct Main {
    static func main() async {
        exit(await CLIRunner.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}

enum CLIRunner {

    static let usage = """
    usage: dicyanin-usdz <subcommand>
      info <file.usd[z|a|c]>   Print stage metadata and the prim tree.
    """

    static func run(
        arguments: [String],
        openStage: (URL) async throws -> any USDStageProtocol = defaultOpen,
        print output: (String) -> Void = { print($0) },
        printError: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        guard let subcommand = arguments.first else {
            printError(usage)
            return 2
        }
        switch subcommand {
        case "info":
            guard arguments.count == 2 else {
                printError(usage)
                return 2
            }
            do {
                let stage = try await openStage(URL(fileURLWithPath: arguments[1]))
                output(render(stage))
                return 0
            } catch {
                let bridgeError = error as? BridgeError
                printError("error: \(bridgeError?.errorDescription ?? error.localizedDescription)")
                if let suggestion = bridgeError?.recoverySuggestion {
                    printError(suggestion)
                }
                return 1
            }
        default:
            printError("unknown subcommand: \(subcommand)\n" + usage)
            return 2
        }
    }

    static func render(_ stage: any USDStageProtocol) -> String {
        var lines: [String] = []
        let metadata = stage.metadata
        lines.append("upAxis: \(metadata.upAxis.rawValue)  metersPerUnit: \(metadata.metersPerUnit)"
            + (metadata.defaultPrim.map { "  defaultPrim: \($0)" } ?? ""))
        lines.append("prims: \(stage.primCount)")
        func walk(_ prim: Prim) {
            let indent = String(repeating: "  ", count: prim.path.depth - 1)
            var flags: [String] = []
            if !prim.isActive { flags.append("inactive") }
            if prim.visibility == .invisible { flags.append("hidden") }
            let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append("\(indent)\(prim.name) (\(prim.typeName.isEmpty ? "def" : prim.typeName))\(suffix)")
            prim.children.forEach(walk)
        }
        stage.rootPrims.forEach(walk)
        return lines.joined(separator: "\n")
    }

    static func defaultOpen(url: URL) async throws -> any USDStageProtocol {
        guard let executor = ProcessBridgeExecutor(scriptPath: try snapshotScriptPath()) else {
            throw BridgeError.pythonUnavailable(detail: "no Python interpreter found")
        }
        return try await BridgedStage.open(url: url, executor: executor)
    }

    /// Finds `Resources/Python/stage_snapshot.py` by walking up from the cwd
    /// (works from the repo root, CLI/, or a build directory), with a
    /// `DICYANIN_SNAPSHOT_SCRIPT` env override for installed binaries.
    static func snapshotScriptPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startingAt directory: String = FileManager.default.currentDirectoryPath
    ) throws -> String {
        if let override = environment["DICYANIN_SNAPSHOT_SCRIPT"], !override.isEmpty {
            return override
        }
        var dir = URL(fileURLWithPath: directory)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Python/stage_snapshot.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir.deleteLastPathComponent()
        }
        throw BridgeError.pythonUnavailable(detail: "stage_snapshot.py not found; set DICYANIN_SNAPSHOT_SCRIPT")
    }
}
