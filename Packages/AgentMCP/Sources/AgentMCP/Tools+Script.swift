import Foundation
import ScriptingKit
import USDCore

/// §3.7 Escape hatch — sandboxed Python scripting via ScriptingKit's
/// manifest/limits surface, never raw interpreter access. Used only for the
/// long tail the typed verbs don't cover.
public enum ScriptTools {

    public static func register(
        on server: MCPServer, session: EditSession,
        executor: (any ScriptExecuting)?,
        workDirectory: URL
    ) {
        server.register(MCPTool(
            name: "run_script", group: .script,
            description: "Run a manifested Python script headless against the current stage (saved to a temp .usda first). Arguments are validated against the script's manifest. Returns stdout, progress log, and the output file path (import it via import_asset).",
            inputSchema: Schema.object([
                "script": Schema.string("path to a .py script exposing --emit-manifest"),
                "args": .object(["description": "script argument name → value (validated against the manifest)"]),
                "dryRun": Schema.boolean("validate + plan without writing output (default false)"),
            ], required: ["script"])
        ) { args in
            guard let executor else {
                throw ToolError.unsupported("scripting unavailable: no Python executor configured")
            }
            guard let scriptPath = args["script"].stringValue else {
                throw ToolError.invalidParams("missing 'script'")
            }
            let scriptURL = URL(fileURLWithPath: scriptPath)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                throw ToolError.invalidParams("no script at \(scriptURL.path)")
            }

            let runner = ScriptRunner(executor: executor)
            let manifest: ScriptManifest
            do {
                manifest = try await runner.loadManifest(script: scriptURL)
            } catch {
                throw ToolError.failed("manifest load failed: \(error)")
            }

            // Stage in: author the current session stage to a temp usda.
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let inputURL = workDirectory.appendingPathComponent("script-input.usda")
            let usda = USDASerializer.serialize(session.stage)
            try usda.write(to: inputURL, atomically: true, encoding: .utf8)

            var values: [String: String] = [:]
            if let object = args["args"].objectValue {
                for (key, value) in object {
                    guard manifest.argument(named: key) != nil else {
                        throw ToolError.invalidParams(
                            "script has no argument '\(key)' (\(manifest.arguments.map(\.name).joined(separator: ", ")))")
                    }
                    switch value {
                    case .string(let s): values[key] = s
                    case .number(let n): values[key] = n.rounded() == n ? String(Int(n)) : String(n)
                    case .bool(let b): values[key] = b ? "true" : "false"
                    default:
                        throw ToolError.invalidParams("argument '\(key)' must be a scalar")
                    }
                }
            }

            let options = ScriptRunOptions(
                outputURL: workDirectory.appendingPathComponent("script-output.usda"),
                dryRun: args["dryRun"].boolValue ?? false,
                argumentValues: values)
            let result: ScriptRunResult
            do {
                result = try await runner.run(
                    script: scriptURL, manifest: manifest, input: inputURL, options: options)
            } catch let error as ScriptRunError {
                throw ToolError.failed("script failed: \(error)")
            }

            var payload: [String: JSONValue] = [
                "script": .string(manifest.name),
                "mutates": .bool(manifest.mutates),
                "stdout": .string(result.standardOutput),
                "log": .array(result.log.map { .string($0) }),
                "producedFile": .bool(result.producedFile),
            ]
            if let outputURL = result.outputURL, result.producedFile {
                payload["outputPath"] = .string(outputURL.path)
                payload["next"] = "call import_asset with this outputPath to bring the result into the stage through the normalization path"
            }
            if let progress = result.lastProgress {
                payload["lastProgress"] = .object([
                    "fraction": .number(progress.fraction),
                    "message": .string(progress.message),
                ])
            }
            return .object(payload)
        })
    }
}
