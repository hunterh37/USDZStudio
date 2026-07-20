import Foundation
import ScriptingKit
import Testing
import USDCore
@testable import AgentMCP

/// Deterministic stub generator (no network).
struct StubGenerator: AssetGenerating {
    var name: String
    var result: Result<URL, ToolError>

    func generate(prompt: String, options: JSONValue) async throws -> URL {
        try result.get()
    }
}

@Suite struct AssetToolTests {

    static func objFixture(in directory: URL, named name: String = "crate.obj") -> URL {
        let obj = """
        v -0.5 -0.5 -0.5
        v  0.5 -0.5 -0.5
        v  0.5  0.5 -0.5
        v -0.5  0.5 -0.5
        v -0.5 -0.5  0.5
        v  0.5 -0.5  0.5
        v  0.5  0.5  0.5
        v -0.5  0.5  0.5
        f 1 2 3 4
        f 5 8 7 6
        f 1 5 6 2
        f 2 6 7 3
        f 3 7 8 4
        f 5 1 4 8
        """
        let url = directory.appendingPathComponent(name)
        try? obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importOBJGraftsNormalizesAndValidates() async {
        let work = Fixtures.tempDirectory()
        let objURL = Self.objFixture(in: work)
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)

        let imported = await callOK(server, "import_asset", ["url": .string(objURL.path)])
        let container = imported["path"].stringValue!
        #expect(container.hasPrefix("/crate"))
        #expect(imported["validation"] != .null)
        // The graft is undoable.
        _ = await callOK(server, "get_prim", ["path": .string(container)])
        // Second import of the same name gets a fresh container.
        let again = await callOK(server, "import_asset", ["url": .string(objURL.path)])
        #expect(again["path"].stringValue != container)

        _ = await callError(server, "import_asset", ["url": "/nope/missing.obj"])
        let unsupported = work.appendingPathComponent("weird.xyz")
        try? Data("x".utf8).write(to: unsupported)
        _ = await callError(server, "import_asset", ["url": .string(unsupported.path)])
        _ = await callError(server, "import_asset", .object([:]))
        // USD-family file without a bridge executor → structured unsupported.
        let usdz = work.appendingPathComponent("thing.usdz")
        try? Data("x".utf8).write(to: usdz)
        let message = await callError(server, "import_asset", ["url": .string(usdz.path)])
        #expect(message.contains("Python bridge"))
    }

    @Test func normalizeScalesImplausibleSubtrees() async {
        let session = Fixtures.session()
        let server = Fixtures.server(session: session)
        // 1m box is already plausible for a 1m target → no-op.
        let plausible = await callOK(server, "normalize_asset", ["path": "/Root/Box"])
        #expect(plausible["scaled"].boolValue == false)
        // Blow it up to 500m, normalize back to ~2m.
        _ = await callOK(server, "set_transform", ["path": "/Root/Box", "scale": [500, 500, 500]])
        let normalized = await callOK(server, "normalize_asset",
                                      ["path": "/Root/Box", "targetMaxExtent": 2])
        #expect(normalized["scaled"].boolValue == true)
        let box = GeometryProbe.worldBBox(of: PrimPath("/Root/Box")!, in: session.stage)!
        #expect(abs(box.maxExtent - 2) < 1e-6)

        _ = await callError(server, "normalize_asset", ["path": "/Root/Box", "targetMaxExtent": -1])
        _ = await callOK(server, "create_prim", ["name": "Hollow"])
        _ = await callError(server, "normalize_asset", ["path": "/Hollow"])
    }

    @Test func searchAssetsScansLibraries() async {
        let library = Fixtures.tempDirectory()
        _ = Self.objFixture(in: library, named: "old_crate.obj")
        _ = Self.objFixture(in: library, named: "barrel.obj")
        try? Data().write(to: library.appendingPathComponent("crate_texture.png"))
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(libraryDirectories: [library]))

        let hits = await callOK(server, "search_assets", ["query": "crate"])
        let results = hits["results"].arrayValue!
        #expect(results.count == 1)  // png filtered out, barrel not matching
        #expect(results[0]["name"].stringValue == "old_crate.obj")
        let limited = await callOK(server, "search_assets", ["query": ".obj", "limit": 1])
        #expect(limited["results"].arrayValue?.count == 1)
        _ = await callError(server, "search_assets", .object([:]))
    }

    @Test func generatePollFetchLifecycle() async throws {
        let work = Fixtures.tempDirectory()
        let asset = Self.objFixture(in: work, named: "generated.obj")
        let session = Fixtures.session()
        let server = Fixtures.server(
            session: session,
            configuration: .init(generators: [
                StubGenerator(name: "stub", result: .success(asset)),
                StubGenerator(name: "broken", result: .failure(.failed("provider exploded"))),
            ]))

        let submitted = await callOK(server, "generate_asset", ["prompt": "a crate"])
        let jobId = submitted["jobId"].stringValue!
        #expect(submitted["provider"].stringValue == "stub")

        // Poll until done (stub resolves almost immediately).
        var status = JSONValue.null
        for _ in 0..<100 {
            status = await callOK(server, "asset_job_status", ["jobId": .string(jobId)])
            if status["status"].stringValue != "running" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(status["status"].stringValue == "done")
        #expect(status["path"].stringValue == asset.path)

        let fetched = await callOK(server, "fetch_asset", ["jobId": .string(jobId), "name": "GenCrate"])
        #expect(fetched["path"].stringValue == "/GenCrate")

        // Failing provider → failed status; fetch refuses.
        let failing = await callOK(server, "generate_asset",
                                   ["prompt": "x", "provider": "broken"])
        let failedID = failing["jobId"].stringValue!
        var failedStatus = JSONValue.null
        for _ in 0..<100 {
            failedStatus = await callOK(server, "asset_job_status", ["jobId": .string(failedID)])
            if failedStatus["status"].stringValue != "running" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(failedStatus["status"].stringValue == "failed")
        _ = await callError(server, "fetch_asset", ["jobId": .string(failedID)])

        _ = await callError(server, "generate_asset", ["prompt": "x", "provider": "nope"])
        _ = await callError(server, "generate_asset", .object([:]))
        _ = await callError(server, "asset_job_status", ["jobId": "job-404"])
        _ = await callError(server, "fetch_asset", ["jobId": "job-404"])
    }

    @Test func noProvidersConfigured() async {
        let server = Fixtures.server(session: Fixtures.session())
        let message = await callError(server, "generate_asset", ["prompt": "a crate"])
        #expect(message.contains("no generation providers"))
    }
}

/// Scripted `ScriptExecuting` stub: emits a manifest for --emit-manifest,
/// otherwise "runs" by writing the -o output file and printing progress.
struct StubScriptExecutor: ScriptExecuting {
    var manifest: ScriptManifest
    var exitCode: Int32 = 0

    func execute(
        scriptPath: String, arguments: [String],
        onStandardErrorLine: (@Sendable (String) -> Void)?
    ) async throws -> ScriptProcessResult {
        if arguments == [ScriptRunner.emitManifestFlag] {
            let data = try JSONEncoder().encode(manifest)
            return ScriptProcessResult(
                exitCode: 0, standardOutput: String(decoding: data, as: UTF8.self), standardError: "")
        }
        guard exitCode == 0 else {
            return ScriptProcessResult(exitCode: exitCode, standardOutput: "", standardError: "boom")
        }
        if let flag = arguments.firstIndex(of: "-o"), flag + 1 < arguments.count {
            try Data("#usda 1.0\n".utf8).write(to: URL(fileURLWithPath: arguments[flag + 1]))
        }
        onStandardErrorLine?("PROGRESS 0.5 halfway")
        onStandardErrorLine?("some log line")
        return ScriptProcessResult(exitCode: 0, standardOutput: "done", standardError: "")
    }
}

@Suite struct ScriptToolTests {

    static let manifest = ScriptManifest(
        name: "decimate", description: "test script", mutates: true,
        arguments: [ScriptArgument(name: "ratio", kind: .float)])

    static func makeServer(executor: (any ScriptExecuting)?) -> (MCPServer, URL) {
        let work = Fixtures.tempDirectory()
        let server = Fixtures.server(
            session: Fixtures.session(),
            configuration: .init(scriptExecutor: executor, workDirectory: work))
        return (server, work)
    }

    static func scriptFile(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("decimate.py")
        try? "print('hi')".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func runsScriptWithManifestValidation() async {
        let (server, work) = Self.makeServer(executor: StubScriptExecutor(manifest: Self.manifest))
        let script = Self.scriptFile(in: work)

        let result = await callOK(server, "run_script",
                                  ["script": .string(script.path),
                                   "args": ["ratio": 0.5]])
        #expect(result["script"].stringValue == "decimate")
        #expect(result["mutates"].boolValue == true)
        #expect(result["producedFile"].boolValue == true)
        #expect(result["outputPath"].stringValue?.hasSuffix("script-output.usda") == true)
        #expect(result["stdout"].stringValue == "done")
        // Stage was authored as the script input.
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("script-input.usda").path))

        // Unknown argument rejected against the manifest, pre-execution.
        let unknown = await callError(server, "run_script",
                                      ["script": .string(script.path), "args": ["nope": 1]])
        #expect(unknown.contains("no argument 'nope'"))
        _ = await callError(server, "run_script",
                            ["script": .string(script.path), "args": ["ratio": ["not", "scalar"]]])
        _ = await callError(server, "run_script", ["script": "/missing.py"])
        _ = await callError(server, "run_script", .object([:]))

        // Scalar coercions: int-ish and bool arguments pass through.
        let coerced = await callOK(server, "run_script",
                                   ["script": .string(script.path), "args": ["ratio": 1]])
        #expect(coerced["producedFile"].boolValue == true)
    }

    @Test func dryRunProducesNoFile() async {
        let (server, work) = Self.makeServer(executor: StubScriptExecutor(manifest: Self.manifest))
        let script = Self.scriptFile(in: work)
        try? FileManager.default.removeItem(at: work.appendingPathComponent("script-output.usda"))
        let result = await callOK(server, "run_script",
                                  ["script": .string(script.path), "dryRun": true])
        #expect(result["producedFile"].boolValue == false)
        #expect(result["outputPath"].isNull)
    }

    @Test func scriptFailureIsStructured() async {
        let (server, work) = Self.makeServer(
            executor: StubScriptExecutor(manifest: Self.manifest, exitCode: 3))
        let script = Self.scriptFile(in: work)
        let message = await callError(server, "run_script", ["script": .string(script.path)])
        #expect(message.contains("script failed"))
    }

    @Test func noExecutorConfigured() async {
        let (server, work) = Self.makeServer(executor: nil)
        let script = Self.scriptFile(in: work)
        let message = await callError(server, "run_script", ["script": .string(script.path)])
        #expect(message.contains("scripting unavailable"))
    }
}
