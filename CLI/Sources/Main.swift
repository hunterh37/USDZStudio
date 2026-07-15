import ConversionKit
import Foundation
import USDCore
import USDBridge
import ValidationKit

/// Phase 0 CLI: `dicyanin-usdz info <file>` prints the prim tree.
/// `convert`, `run`, and `validate` add Phase 2/4 pipeline capabilities
/// (specs/scripting.md, specs/validation.md). Exit codes: 0 ok, 1 runtime
/// failure / validation gate failure, 2 usage.
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
      convert <input> <output.usda> [--preset NAME] [--max-texture-size N]
                     [--jpeg-basecolor]
                               Convert glTF/GLB/OBJ/STL/PLY/DAE to USD.
      convert-batch <manifest.csv> [--out-dir DIR] [--report FILE.{csv,json}]
                     [--preset NAME] [--max-texture-size N] [--jpeg-basecolor]
                     [--no-overwrite]
                               Convert every row of a CSV manifest (columns:
                               input[,output]); prints a summary, exits 1 if
                               any job failed.
      run <script[.py]> <file.usd[z|a|c]> [script flags...]
                               Run a Python script (bundled name or path)
                               headless against a stage. Remaining flags pass
                               through to the script (see its --help). Exit code
                               is the script's own.
      validate <file.usd[z|a|c]> [--strict]
                               Run the AR QuickLook / ARKit rule catalog and
                               print diagnostics (most-severe first). Exits 1 if
                               any error is found; with --strict, warnings fail
                               the gate too.

      --preset NAME            Base texture settings before other flags apply.
                               NAME is one of: quicklook-strict (default),
                               ecommerce, lossless.
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
        case "convert-batch":
            return await convertBatch(arguments: Array(arguments.dropFirst()), print: output, printError: printError)
        case "run":
            return runScript(arguments: Array(arguments.dropFirst()), printError: printError)
        case "validate":
            return await validate(
                arguments: Array(arguments.dropFirst()),
                openStage: openStage, print: output, printError: printError)
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
        var overrides = PolicyOverrides()
        switch overrides.parse(&positional, arguments: arguments, printError: printError) {
        case .fail(let code): return code
        case .ok: break
        }
        let policy: TexturePolicy
        switch overrides.resolve(printError: printError) {
        case .fail(let code): return code
        case .policy(let resolved): policy = resolved
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
        guard ImporterRegistry.standard.importer(for: inputURL) != nil else {
            printError("error: unsupported input format .\(inputURL.pathExtension) (supported: \(ImporterRegistry.standard.registeredExtensions.joined(separator: ", ")))")
            return 2
        }

        do {
            let outcome = try await SingleFileConverter.convert(input: inputURL, texturePolicy: policy)
            try Data(outcome.usda.utf8).write(to: outputURL)

            outcome.log.forEach(output)
            for diagnostic in outcome.diagnostics {
                printError("\(diagnostic.severity.rawValue): [\(diagnostic.stage)] \(diagnostic.message)")
            }
            output("wrote \(outputURL.path)")
            return 0
        } catch {
            printError("error: \(error)")
            return 1
        }
    }

    // MARK: - convert-batch

    /// A CSV manifest row: `input` (required) and an optional explicit
    /// `output`. A leading `input,output` header row is tolerated.
    static func parseManifest(_ text: String) -> [(input: String, output: String?)] {
        var rows: [(String, String?)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let input = cells[0]
            if input.isEmpty { continue }
            if input.caseInsensitiveCompare("input") == .orderedSame { continue }  // header
            let output = cells.count > 1 && !cells[1].isEmpty ? cells[1] : nil
            rows.append((input, output))
        }
        return rows
    }

    static func convertBatch(
        arguments: [String],
        print output: (String) -> Void,
        printError: (String) -> Void
    ) async -> Int32 {
        var positional: [String] = []
        var overrides = PolicyOverrides()
        var outDir: String?
        var reportPath: String?
        var overwrite = true
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch overrides.consume(arguments, at: index, printError: printError) {
            case .error(let code): return code
            case .consumed(let count): index += count; continue
            case .notHandled: break
            }
            switch argument {
            case "--out-dir":
                guard index + 1 < arguments.count else {
                    printError("error: --out-dir needs a directory path")
                    return 2
                }
                outDir = arguments[index + 1]
                index += 2
            case "--report":
                guard index + 1 < arguments.count else {
                    printError("error: --report needs a file path")
                    return 2
                }
                reportPath = arguments[index + 1]
                index += 2
            case "--no-overwrite":
                overwrite = false
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
        guard positional.count == 1 else {
            printError(usage)
            return 2
        }
        let policy: TexturePolicy
        switch overrides.resolve(printError: printError) {
        case .fail(let code): return code
        case .policy(let resolved): policy = resolved
        }
        if let reportPath, !["csv", "json"].contains((reportPath as NSString).pathExtension.lowercased()) {
            printError("error: --report must end in .csv or .json")
            return 2
        }

        let manifestURL = URL(fileURLWithPath: positional[0])
        guard let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            printError("error: could not read manifest \(manifestURL.path)")
            return 1
        }
        let rows = parseManifest(manifestText)
        guard !rows.isEmpty else {
            printError("error: manifest has no input rows")
            return 2
        }

        // Resolve relative paths against the manifest's directory; default
        // outputs land next to inputs (or in --out-dir) with a .usda suffix.
        let manifestDir = manifestURL.deletingLastPathComponent()
        let outDirURL = outDir.map { URL(fileURLWithPath: $0) }
        var jobs: [BatchJob] = []
        for row in rows {
            let inputURL = URL(fileURLWithPath: row.input, relativeTo: manifestDir).standardizedFileURL
            let outputURL: URL
            if let explicit = row.output {
                outputURL = URL(fileURLWithPath: explicit, relativeTo: manifestDir).standardizedFileURL
            } else {
                let name = inputURL.deletingPathExtension().lastPathComponent + ".usda"
                outputURL = (outDirURL ?? inputURL.deletingLastPathComponent())
                    .appendingPathComponent(name)
            }
            jobs.append(BatchJob(input: inputURL, output: outputURL))
        }

        let converter = BatchConverter(texturePolicy: policy, overwrite: overwrite)
        let report = await converter.run(jobs) { item in
            let mark: String
            switch item.status {
            case .succeeded: mark = "ok  "
            case .failed: mark = "FAIL"
            case .skipped: mark = "skip"
            }
            var line = "[\(mark)] \(item.input)"
            if item.status == .succeeded {
                line += " → \(item.output) (\(item.triangleCount) tris, \(item.warningCount) warn)"
            } else if let message = item.message {
                line += " — \(message)"
            }
            output(line)
        }

        if let reportPath {
            let reportURL = URL(fileURLWithPath: reportPath)
            do {
                let data = (reportURL.pathExtension.lowercased() == "json")
                    ? try report.jsonData()
                    : Data(report.csv.utf8)
                try data.write(to: reportURL)
                output("report: \(reportURL.path)")
            } catch {
                printError("error: could not write report — \(error)")
                return 1
            }
        }

        output("batch: \(report.succeededCount) ok, \(report.failedCount) failed, \(report.skippedCount) skipped (\(jobs.count) total)")
        return report.hasFailures ? 1 : 0
    }

    // MARK: - run

    /// A fully-resolved script invocation: which interpreter, the argv to hand
    /// it (`script model [flags...]`), and the directories that must be on
    /// `PYTHONPATH` so `from _harness import …` resolves.
    struct RunInvocation: Equatable {
        var python: String
        var arguments: [String]
        var pythonPath: [String]
    }

    enum RunResolution: Equatable {
        case invocation(RunInvocation)
        case fail(Int32)
    }

    /// Pure, testable resolution of a `run` command: locates the script (by
    /// path or bundled name), the interpreter, and the `_harness` search path.
    /// Does *not* touch the model file — the harness opens and validates it,
    /// reporting its own errors.
    static func resolveRun(
        arguments: [String],
        locatePython: () -> String?,
        fileExists: (String) -> Bool,
        bundledScriptsDir: () -> String?,
        printError: (String) -> Void
    ) -> RunResolution {
        guard arguments.count >= 2 else {
            printError("error: run needs a script and a file\n" + usage)
            return .fail(2)
        }
        let scriptArg = arguments[0]
        let passthrough = Array(arguments.dropFirst())  // model + script flags

        let scriptsDir = bundledScriptsDir()
        // Candidate resolutions, in priority order: exact path, path+.py, then
        // the same two under the bundled scripts directory.
        var candidates = [scriptArg, scriptArg + ".py"]
        if let scriptsDir {
            let base = URL(fileURLWithPath: scriptsDir)
            candidates.append(base.appendingPathComponent(scriptArg).path)
            candidates.append(base.appendingPathComponent(scriptArg + ".py").path)
        }
        guard let resolved = candidates.first(where: fileExists) else {
            printError("error: script not found: \(scriptArg)")
            return .fail(2)
        }

        guard let python = locatePython() else {
            printError("error: no Python interpreter found (set DICYANIN_PYTHON)")
            return .fail(1)
        }

        // `_harness` lives beside the bundled scripts; also expose the resolved
        // script's own directory so a user script sitting elsewhere can import
        // its own siblings.
        var pythonPath = [URL(fileURLWithPath: resolved).deletingLastPathComponent().path]
        if let scriptsDir, !pythonPath.contains(scriptsDir) {
            pythonPath.append(scriptsDir)
        }

        return .invocation(RunInvocation(
            python: python,
            arguments: [resolved] + passthrough,
            pythonPath: pythonPath))
    }

    static func runScript(
        arguments: [String],
        printError: (String) -> Void,
        spawn: (RunInvocation) -> Int32 = defaultSpawn
    ) -> Int32 {
        let locator = PythonRuntimeLocator()
        let resolution = resolveRun(
            arguments: arguments,
            locatePython: { locator.locate() },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            bundledScriptsDir: { try? scriptsDirectoryPath() },
            printError: printError)
        switch resolution {
        case .fail(let code): return code
        case .invocation(let invocation): return spawn(invocation)
        }
    }

    /// Runs the interpreter, inheriting stdio so the script's stdout/stderr and
    /// exit code flow straight through. Prepends our search dirs to any
    /// inherited `PYTHONPATH`.
    static func defaultSpawn(_ invocation: RunInvocation) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.python)
        process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PYTHONPATH"]
        environment["PYTHONPATH"] = (invocation.pythonPath + (existing.map { [$0] } ?? []))
            .joined(separator: ":")
        process.environment = environment
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("error: could not launch \(invocation.python): \(error)\n".utf8))
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Locates the bundled `Resources/Python/scripts` directory the same way
    /// `snapshotScriptPath` finds the snapshot script: a `DICYANIN_SCRIPTS_DIR`
    /// override, else a walk up from the cwd.
    static func scriptsDirectoryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startingAt directory: String = FileManager.default.currentDirectoryPath
    ) throws -> String {
        if let override = environment["DICYANIN_SCRIPTS_DIR"], !override.isEmpty {
            return override
        }
        var dir = URL(fileURLWithPath: directory)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Python/scripts")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.path
            }
            dir.deleteLastPathComponent()
        }
        throw BridgeError.pythonUnavailable(detail: "Resources/Python/scripts not found; set DICYANIN_SCRIPTS_DIR")
    }

    // MARK: - validate

    static func validate(
        arguments: [String],
        openStage: (URL) async throws -> any USDStageProtocol,
        print output: (String) -> Void,
        printError: (String) -> Void
    ) async -> Int32 {
        var positional: [String] = []
        var strict = false
        for argument in arguments {
            switch argument {
            case "--strict":
                strict = true
            default:
                if argument.hasPrefix("--") {
                    printError("error: unknown option \(argument)\n" + usage)
                    return 2
                }
                positional.append(argument)
            }
        }
        guard positional.count == 1 else {
            printError(usage)
            return 2
        }

        let stage: any USDStageProtocol
        do {
            stage = try await openStage(URL(fileURLWithPath: positional[0]))
        } catch {
            let bridgeError = error as? BridgeError
            printError("error: \(bridgeError?.errorDescription ?? error.localizedDescription)")
            if let suggestion = bridgeError?.recoverySuggestion {
                printError(suggestion)
            }
            return 1
        }

        let report = ValidationEngine.arkitProfile.validate(stage)
        renderReport(report, print: output)

        // Errors always fail the gate; --strict escalates warnings too.
        let failed = !report.isCompliant || (strict && report.warningCount > 0)
        return failed ? 1 : 0
    }

    /// Renders a `ValidationReport` as one line per diagnostic (already sorted
    /// most-severe first by the engine) followed by a summary line.
    static func renderReport(_ report: ValidationReport, print output: (String) -> Void) {
        for diagnostic in report.diagnostics {
            let location = diagnostic.primPath.map { " (\($0))" } ?? ""
            output("\(diagnostic.severity.rawValue): [\(diagnostic.ruleID)] \(diagnostic.message)\(location)")
        }
        let summary = "\(report.errorCount) error\(report.errorCount == 1 ? "" : "s"), "
            + "\(report.warningCount) warning\(report.warningCount == 1 ? "" : "s"), "
            + "\(report.infoCount) info"
        let verdict = report.isCompliant ? "AR-compliant" : "not AR-compliant"
        output("\(summary) — \(verdict)")
    }

    // MARK: - shared texture-policy options

    /// Collects the texture-policy command-line options shared by `convert`
    /// and `convert-batch`: a `--preset` base plus `--max-texture-size` /
    /// `--jpeg-basecolor` overrides that win over whatever the preset set,
    /// regardless of argument order.
    struct PolicyOverrides {
        var presetID: String?
        var maxSize: Int?
        var jpeg: Bool?

        enum Consumed {
            case consumed(Int)
            case notHandled
            case error(Int32)
        }

        enum ParseOutcome {
            case ok
            case fail(Int32)
        }

        enum ResolveOutcome {
            case policy(TexturePolicy)
            case fail(Int32)
        }

        /// Handles a single argument if it's a texture-policy option.
        mutating func consume(
            _ arguments: [String],
            at index: Int,
            printError: (String) -> Void
        ) -> Consumed {
            switch arguments[index] {
            case "--preset":
                guard index + 1 < arguments.count else {
                    printError("error: --preset needs a name (\(ConversionPreset.identifiers))")
                    return .error(2)
                }
                presetID = arguments[index + 1]
                return .consumed(2)
            case "--max-texture-size":
                guard index + 1 < arguments.count, let size = Int(arguments[index + 1]), size > 0 else {
                    printError("error: --max-texture-size needs a positive integer")
                    return .error(2)
                }
                maxSize = size
                return .consumed(2)
            case "--jpeg-basecolor":
                jpeg = true
                return .consumed(1)
            default:
                return .notHandled
            }
        }

        /// Full-argument parse for subcommands with no options of their own
        /// (`convert`): texture-policy flags are consumed, anything else is a
        /// positional, and an unknown `--flag` is an error.
        mutating func parse(
            _ positional: inout [String],
            arguments: [String],
            printError: (String) -> Void
        ) -> ParseOutcome {
            var index = 0
            while index < arguments.count {
                switch consume(arguments, at: index, printError: printError) {
                case .error(let code): return .fail(code)
                case .consumed(let count): index += count
                case .notHandled:
                    let argument = arguments[index]
                    if argument.hasPrefix("--") {
                        printError("error: unknown option \(argument)\n" + usage)
                        return .fail(2)
                    }
                    positional.append(argument)
                    index += 1
                }
            }
            return .ok
        }

        /// Applies the preset (if named) then layers explicit flag overrides
        /// on top. An unknown preset name is a usage error.
        func resolve(printError: (String) -> Void) -> ResolveOutcome {
            var policy = TexturePolicy()
            if let presetID {
                guard let preset = ConversionPreset.named(presetID) else {
                    printError("error: unknown preset '\(presetID)' (choices: \(ConversionPreset.identifiers))")
                    return .fail(2)
                }
                policy = preset.texturePolicy
            }
            if let maxSize { policy.maxSize = maxSize }
            if let jpeg { policy.encodeBaseColorAsJPEG = jpeg }
            return .policy(policy)
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
