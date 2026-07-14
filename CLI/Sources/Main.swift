import ConversionKit
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
      convert <input> <output.usda> [--max-texture-size N] [--jpeg-basecolor]
                               Convert glTF/GLB/OBJ/STL/PLY/DAE to USD.
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
        case "convert":
            return await convert(arguments: Array(arguments.dropFirst()), print: output, printError: printError)
        default:
            printError("unknown subcommand: \(subcommand)\n" + usage)
            return 2
        }
    }

    // MARK: - convert

    static func convert(
        arguments: [String],
        print output: (String) -> Void,
        printError: (String) -> Void
    ) async -> Int32 {
        var positional: [String] = []
        var policy = TexturePolicy()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--max-texture-size":
                guard index + 1 < arguments.count, let size = Int(arguments[index + 1]), size > 0 else {
                    printError("error: --max-texture-size needs a positive integer")
                    return 2
                }
                policy.maxSize = size
                index += 2
            case "--jpeg-basecolor":
                policy.encodeBaseColorAsJPEG = true
                index += 1
            default:
                if argument.hasPrefix("--") {
                    printError("error: unknown option \(argument)\n" + usage)
                    return 2
                }
                positional.append(argument)
                index += 1
            }
        }
        guard positional.count == 2 else {
            printError(usage)
            return 2
        }
        let inputURL = URL(fileURLWithPath: positional[0])
        let outputURL = URL(fileURLWithPath: positional[1])
        guard outputURL.pathExtension.lowercased() == "usda" else {
            printError("error: only .usda output is supported for now (usdz packaging is coming)")
            return 2
        }
        guard let importer = ImporterRegistry.standard.importer(for: inputURL) else {
            printError("error: unsupported input format .\(inputURL.pathExtension) (supported: \(ImporterRegistry.standard.registeredExtensions.joined(separator: ", ")))")
            return 2
        }

        do {
            let imported = try await importer.importAsset(at: inputURL, options: ImportOptions(maxTextureSize: policy.maxSize))
            var context = ConversionContext(sourceURL: inputURL, scene: imported.scene, diagnostics: imported.diagnostics)
            context.log.append("parse: ok (\(imported.scene.triangleCount) triangles, \(imported.scene.materials.count) materials)")
            context = try await ConversionPipeline.standard(texturePolicy: policy).run(context)

            guard let stage = context.authoredStage else {
                // coverage:disable — the standard pipeline always ends in
                // USDAuthorStage, which populates authoredStage or throws.
                printError("error: pipeline produced no stage")
                return 1
            }
            try USDASerializer.serialize(stage).data(using: .utf8)!.write(to: outputURL)

            context.log.forEach(output)
            for diagnostic in context.diagnostics {
                printError("\(diagnostic.severity.rawValue): [\(diagnostic.stage)] \(diagnostic.message)")
            }
            output("wrote \(outputURL.path)")
            return 0
        } catch {
            printError("error: \(error)")
            return 1
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
