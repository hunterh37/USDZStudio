import Foundation
import ConversionKit
import EditingKit
import USDBridge
import USDCore

/// Pluggable text/image-to-3D provider (docs/AGENT_MCP_PLAN.md §3.5 —
/// generation is submit/poll/import, never blocking a tool call on a cloud
/// render; provider keys via env vars; the MCP server owns import hygiene).
public protocol AssetGenerating: Sendable {
    var name: String { get }
    /// Produce a local model file (USDZ/GLTF/OBJ…) for the prompt.
    func generate(prompt: String, options: JSONValue) async throws -> URL
}

/// In-session async job registry for `generate_asset` → `asset_job_status`
/// → `fetch_asset`.
public actor AssetJobStore {
    public enum State: Sendable {
        case running
        case done(URL)
        case failed(String)
    }

    private var jobs: [String: State] = [:]
    private var serial = 0

    public init() {}

    public func createJob() -> String {
        serial += 1
        let id = "job-\(serial)"
        jobs[id] = .running
        return id
    }

    public func finish(_ id: String, url: URL) { jobs[id] = .done(url) }
    public func fail(_ id: String, message: String) { jobs[id] = .failed(message) }
    public func state(of id: String) -> State? { jobs[id] }
}

/// §3.5 Asset tools — "import is not integration": every entry point funnels
/// through the same import → normalize → validate hygiene path.
public enum AssetTools {

    public static func register(
        on server: MCPServer, session: EditSession,
        generators: [any AssetGenerating],
        libraryDirectories: [URL],
        jobs: AssetJobStore
    ) {
        server.register(MCPTool(
            name: "import_asset", group: .asset,
            description: "Import a model file (glTF/GLB/OBJ/STL/PLY/DAE) through the conversion pipeline, graft it under a new root Xform, then auto-normalize scale. One undo step. Returns the container path and pipeline diagnostics.",
            inputSchema: Schema.object([
                "url": Schema.string("local file path of the asset"),
                "name": Schema.string("container prim name (default from filename)"),
                "maxTextureSize": Schema.integer("clamp imported textures (optional)"),
            ], required: ["url"])
        ) { args in
            try await importAsset(args: args, session: session)
        })

        server.register(MCPTool(
            name: "normalize_asset", group: .asset,
            description: "Auto-scale a subtree to a plausible real-world size (target max extent in meters, default 1.0) by adjusting its root transform. One undo step.",
            inputSchema: Schema.object([
                "path": Schema.primRef,
                "targetMaxExtent": Schema.number("desired max extent in meters (default 1.0)"),
            ], required: ["path"])
        ) { args in
            let path = try session.resolve(args)
            return try normalize(
                path: path,
                targetMaxExtent: args["targetMaxExtent"].doubleValue ?? 1.0,
                session: session)
        })

        server.register(MCPTool(
            name: "search_assets", group: .asset,
            description: "Search the local asset library folders for model files matching a query (filename substring). Returns candidate paths for import_asset.",
            inputSchema: Schema.object([
                "query": Schema.string("filename substring, case-insensitive"),
                "limit": Schema.integer("max results (default 20)"),
            ], required: ["query"])
        ) { args in
            guard let query = args["query"].stringValue?.lowercased(), !query.isEmpty else {
                throw ToolError.invalidParams("missing 'query'")
            }
            let limit = args["limit"].intValue ?? 20
            let hits = searchLibrary(query: query, directories: libraryDirectories, limit: limit)
            return .object([
                "results": .array(hits.map { url in
                    .object(["path": .string(url.path), "name": .string(url.lastPathComponent)])
                }),
                "searched": .array(libraryDirectories.map { .string($0.path) }),
            ])
        })

        server.register(MCPTool(
            name: "generate_asset", group: .asset,
            description: "Submit a text-to-3D generation job to a configured provider. Async: returns a jobId immediately; poll asset_job_status, then fetch_asset to import.",
            inputSchema: Schema.object([
                "prompt": Schema.string("what to generate"),
                "provider": Schema.string("provider name (defaults to the first configured)"),
            ], required: ["prompt"])
        ) { args in
            guard let prompt = args["prompt"].stringValue, !prompt.isEmpty else {
                throw ToolError.invalidParams("missing 'prompt'")
            }
            let provider: any AssetGenerating
            if let name = args["provider"].stringValue {
                guard let found = generators.first(where: { $0.name == name }) else {
                    throw ToolError.invalidParams(
                        "unknown provider '\(name)' (configured: \(generators.map(\.name).joined(separator: ", ")))")
                }
                provider = found
            } else if let first = generators.first {
                provider = first
            } else {
                throw ToolError.unsupported("no generation providers configured (set provider API keys via env)")
            }
            let jobId = await jobs.createJob()
            let options = args["options"]
            Task {
                do {
                    let url = try await provider.generate(prompt: prompt, options: options)
                    await jobs.finish(jobId, url: url)
                } catch {
                    await jobs.fail(jobId, message: "\(error)")
                }
            }
            return .object(["jobId": .string(jobId), "provider": .string(provider.name)])
        })

        server.register(MCPTool(
            name: "asset_job_status", group: .asset,
            description: "Poll a generate_asset job: running | done | failed.",
            inputSchema: Schema.object(["jobId": Schema.string("job id")], required: ["jobId"])
        ) { args in
            guard let id = args["jobId"].stringValue, let state = await jobs.state(of: id) else {
                throw ToolError.invalidParams("unknown jobId '\(args["jobId"].stringValue ?? "?")'")
            }
            switch state {
            case .running: return .object(["status": "running"])
            case .done(let url): return .object(["status": "done", "path": .string(url.path)])
            case .failed(let message): return .object(["status": "failed", "error": .string(message)])
            }
        })

        server.register(MCPTool(
            name: "fetch_asset", group: .asset,
            description: "Import a completed generate_asset job's file into the stage via the standard import → normalize → validate path.",
            inputSchema: Schema.object([
                "jobId": Schema.string("completed job id"),
                "name": Schema.string("container prim name"),
            ], required: ["jobId"])
        ) { args in
            guard let id = args["jobId"].stringValue, let state = await jobs.state(of: id) else {
                throw ToolError.invalidParams("unknown jobId")
            }
            guard case .done(let url) = state else {
                throw ToolError.failed("job is not done yet — poll asset_job_status")
            }
            var forwarded: [String: JSONValue] = ["url": .string(url.path)]
            if let name = args["name"].stringValue { forwarded["name"] = .string(name) }
            return try await importAsset(args: .object(forwarded), session: session)
        })
    }

    // MARK: - Import (shared by import_asset / fetch_asset / script re-import)

    static func importAsset(args: JSONValue, session: EditSession) async throws -> JSONValue {
        guard let rawURL = args["url"].stringValue else {
            throw ToolError.invalidParams("missing 'url'")
        }
        let url = URL(fileURLWithPath: rawURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.invalidParams("no file at \(url.path)")
        }
        let authored: StageSnapshot
        var pipelineLog: [String] = []
        var pipelineDiagnostics: [JSONValue] = []

        if BridgedStage.supportedExtensions.contains(url.pathExtension.lowercased()) {
            // USD-family file (e.g. a script's output or a downloaded USDZ):
            // reopen through the Python bridge — same snapshot path as `open`.
            guard let bridgeExecutor = session.bridgeExecutor else {
                throw ToolError.unsupported(
                    "importing '.\(url.pathExtension)' needs the Python bridge, which isn't configured")
            }
            do {
                authored = try await BridgedStage.open(url: url, executor: bridgeExecutor).snapshot
            } catch {
                throw ToolError.failed("bridge import failed: \(error)")
            }
            pipelineLog = ["opened \(url.lastPathComponent) via Python bridge"]
        } else {
            let registry = ImporterRegistry.standard
            guard let importer = registry.importer(for: url) else {
                throw ToolError.unsupported(
                    "no importer for '.\(url.pathExtension)' (supported: \(registry.registeredExtensions.joined(separator: ", ")))")
            }

            // Import → pipeline (sanitize, textures, author) — never raw graft.
            let imported: ImportResult
            do {
                imported = try await importer.importAsset(at: url, options: importOptions(from: args))
            } catch {
                throw ToolError.failed("import failed: \(error)")
            }
            let context: ConversionContext
            do {
                context = try await ConversionPipeline.standard()
                    .run(ConversionContext(
                        sourceURL: url, scene: imported.scene, diagnostics: imported.diagnostics))
            } catch {
                // coverage:disable — the standard pipeline's stages throw only on texture-file I/O failures, which need a corrupt on-disk texture corpus (ConversionKit's integration tests own that path).
                throw ToolError.failed("conversion pipeline failed: \(error)")
                // coverage:enable
            }
            authored = try requireAuthoredStage(context, url: url)
            pipelineLog = context.log
            pipelineDiagnostics = diagnosticsJSON(context.diagnostics)
        }
        guard !authored.rootPrims.isEmpty else {
            throw ToolError.failed("\(url.lastPathComponent) contains no prims")
        }

        // Graft under a fresh container root as one undoable step.
        let base = args["name"].stringValue ?? url.deletingPathExtension().lastPathComponent
        let containerName = PrimTree.availableRootName(
            base: base, existing: session.stage.rootPrims)
        guard let containerPath = PrimPath("/\(containerName)") else {
            // coverage:disable — availableRootName() sanitizes through PrimPath.sanitizedName, so the path always parses.
            throw ToolError.failed("cannot form container path for '\(containerName)'")
            // coverage:enable
        }
        var children: [Prim] = []
        var usedNames = Set<String>()
        for root in authored.rootPrims {
            let childName = PrimTree.availableRootName(
                base: root.name, existing: children)
            usedNames.insert(childName)
            if let childPath = containerPath.appending(childName) {
                children.append(PrimTree.rewritten(root, to: childPath))
            }
        }
        let container = Prim(path: containerPath, typeName: "Xform", children: children)
        let insert = InsertPrimCommand(
            prim: container, parent: nil, index: session.stage.rootPrims.count)
        let outcome = try session.mutate(
            CompositeCommand(label: "Import \(url.lastPathComponent)", commands: [insert]))

        // Chain: auto-normalize scale (import is not integration).
        let normalization = try? normalize(path: containerPath, targetMaxExtent: 1.0, session: session)

        return outcome.asJSON(extra: [
            "path": .string(containerPath.description),
            "pipelineLog": .array(pipelineLog.map { .string($0) }),
            "pipelineDiagnostics": .array(pipelineDiagnostics),
            "normalized": normalization ?? .bool(false),
        ])
    }

    private static func importOptions(from args: JSONValue) -> ImportOptions {
        ImportOptions(maxTextureSize: args["maxTextureSize"].intValue)
    }

    /// The pipeline must have authored a non-empty stage before grafting.
    static func requireAuthoredStage(_ context: ConversionContext, url: URL) throws -> StageSnapshot {
        guard let stage = context.authoredStage, !stage.rootPrims.isEmpty else {
            throw ToolError.failed("pipeline produced no authored stage for \(url.lastPathComponent)")
        }
        return stage
    }

    /// ConversionKit diagnostics → tool payload.
    static func diagnosticsJSON(_ diagnostics: [ConversionKit.Diagnostic]) -> [JSONValue] {
        diagnostics.map { d in
            .object(["severity": .string("\(d.severity)"), "message": .string(d.message)])
        }
    }

    // MARK: - Normalize

    static func normalize(path: PrimPath, targetMaxExtent: Double, session: EditSession) throws -> JSONValue {
        guard targetMaxExtent > 0 else {
            throw ToolError.invalidParams("'targetMaxExtent' must be positive")
        }
        guard let box = GeometryProbe.worldBBox(of: path, in: session.stage) else {
            throw ToolError.invalidParams("\(path) has no geometry to normalize")
        }
        let extentMeters = box.maxExtent * session.stage.metadata.metersPerUnit
        guard extentMeters > 0 else {
            throw ToolError.failed("\(path) has zero extent")
        }
        // Already plausible? (within 4x either way of the target) — no-op.
        if extentMeters >= targetMaxExtent / 4, extentMeters <= targetMaxExtent * 4 {
            return .object([
                "scaled": .bool(false),
                "extentMeters": .number(extentMeters),
                "note": "extent already plausible",
            ])
        }
        let factor = targetMaxExtent / extentMeters
        var trs = session.stage.transform(at: path)
        trs.scale = trs.scale.map { $0 * factor }
        let command = SetTransformCommand(
            path: path, newTRS: trs,
            oldAttribute: session.stage.prim(at: path)?.attribute(named: transformAttributeName),
            verb: "Normalize Scale")
        let outcome = try session.mutate(command)
        return outcome.asJSON(extra: [
            "scaled": .bool(true),
            "scaleFactor": .number(factor),
            "extentMetersBefore": .number(extentMeters),
            "extentMetersAfter": .number(targetMaxExtent),
        ])
    }

    // MARK: - Library search

    static let modelExtensions: Set<String> = [
        "usdz", "usda", "usdc", "usd", "gltf", "glb", "obj", "stl", "ply", "dae",
    ]

    static func searchLibrary(query: String, directories: [URL], limit: Int) -> [URL] {
        var hits: [URL] = []
        let fm = FileManager.default
        for directory in directories {
            guard let enumerator = fm.enumerator(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard modelExtensions.contains(url.pathExtension.lowercased()),
                      url.lastPathComponent.lowercased().contains(query)
                else { continue }
                hits.append(url)
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }
}
