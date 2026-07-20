import Testing
import Foundation
import ConversionKit
import USDCore
import USDBridge
import ValidationKit
@testable import openusdz

private func fixtureStage() -> StageSnapshot {
    let wheel = Prim(path: PrimPath("/Car/Wheel")!, typeName: "Mesh", visibility: .invisible)
    let antenna = Prim(path: PrimPath("/Car/Antenna")!, isActive: false)
    let car = Prim(path: PrimPath("/Car")!, typeName: "Xform", children: [wheel, antenna])
    return StageSnapshot(metadata: StageMetadata(metersPerUnit: 0.01, defaultPrim: "Car"), rootPrims: [car])
}

@Suite("CLI exit-code matrix")
struct CLIExitCodeTests {

    private func run(_ args: [String], open: @escaping (URL) async throws -> any USDStageProtocol = { _ in fixtureStage() })
    async -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = []
        var err: [String] = []
        let code = await CLIRunner.run(
            arguments: args, openStage: open,
            print: { out.append($0) }, printError: { err.append($0) })
        return (code, out, err)
    }

    @Test func noArgumentsIsUsageError() async {
        let result = await run([])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("usage") == true)
        #expect(result.out.isEmpty)
    }

    @Test func unknownSubcommandIsUsageError() async {
        let result = await run(["frobnicate"])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("unknown subcommand") == true)
    }

    @Test func infoWithoutFileIsUsageError() async {
        let result = await run(["info"])
        #expect(result.code == 2)
    }

    @Test func infoWithExtraArgsIsUsageError() async {
        let result = await run(["info", "a.usdz", "b.usdz"])
        #expect(result.code == 2)
    }

    @Test func infoSuccessPrintsTree() async {
        let result = await run(["info", "/tmp/car.usdz"])
        #expect(result.code == 0)
        let output = result.out.joined(separator: "\n")
        #expect(output.contains("metersPerUnit: 0.01"))
        #expect(output.contains("defaultPrim: Car"))
        #expect(output.contains("prims: 3"))
        #expect(output.contains("Wheel (Mesh) [hidden]"))
        #expect(output.contains("Antenna (def) [inactive]"))
    }

    @Test func infoFailurePrintsBridgeErrorWithRecovery() async {
        let result = await run(["info", "/tmp/x.usdz"]) { _ in
            throw BridgeError.pythonUnavailable(detail: "nope")
        }
        #expect(result.code == 1)
        #expect(result.err.first?.contains("Python runtime unavailable") == true)
        #expect(result.err.count == 2)  // description + recovery suggestion
    }

    @Test func infoFailureWithNonBridgeError() async {
        struct Boom: Error {}
        let result = await run(["info", "/tmp/x.usdz"]) { _ in throw Boom() }
        #expect(result.code == 1)
        #expect(result.err.count == 1)
    }
}

@Suite("CLI rendering")
struct CLIRenderTests {

    @Test func indentationFollowsDepth() {
        let text = CLIRunner.render(fixtureStage())
        #expect(text.contains("\nCar (Xform)"))
        #expect(text.contains("\n  Wheel"))
    }

    @Test func omitsDefaultPrimWhenAbsent() {
        let text = CLIRunner.render(StageSnapshot())
        #expect(!text.contains("defaultPrim"))
        #expect(text.contains("prims: 0"))
    }
}

// MARK: - convert

@Suite("CLI convert")
struct CLIConvertTests {

    private func run(_ args: [String]) async -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = []
        var err: [String] = []
        let code = await CLIRunner.run(
            arguments: args, openStage: { _ in fixtureStage() },
            print: { out.append($0) }, printError: { err.append($0) })
        return (code, out, err)
    }

    private func makeOBJ() throws -> (input: URL, output: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLIConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("tri.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: input)
        return (input, dir.appendingPathComponent("tri.usda"))
    }

    @Test func convertsOBJToUSDA() async throws {
        let (input, output) = try makeOBJ()
        let result = await run(["convert", input.path, output.path])
        #expect(result.code == 0)
        #expect(result.out.contains { $0.contains("usd-author: ok") })
        #expect(result.out.last?.contains("wrote") == true)
        let usda = try String(contentsOf: output, encoding: .utf8)
        #expect(usda.hasPrefix("#usda 1.0"))
        #expect(usda.contains("point3f[] points"))
    }

    @Test func honorsTextureOptions() async throws {
        let (input, output) = try makeOBJ()
        let result = await run(["convert", "--max-texture-size", "512", "--jpeg-basecolor", input.path, output.path])
        #expect(result.code == 0)
    }

    @Test func wrongArgumentCountIsUsageError() async {
        let result = await run(["convert", "/only/one.obj"])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("usage") == true)
    }

    @Test func badMaxTextureSizeIsUsageError() async {
        for args in [["convert", "--max-texture-size"], ["convert", "--max-texture-size", "zero"], ["convert", "--max-texture-size", "-4"]] {
            let result = await run(args)
            #expect(result.code == 2)
            #expect(result.err.first?.contains("positive integer") == true)
        }
    }

    @Test func unknownOptionIsUsageError() async {
        let result = await run(["convert", "--frobnicate", "/a.obj", "/b.usda"])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("unknown option") == true)
    }

    @Test func nonUSDAOutputRefused() async {
        let result = await run(["convert", "/a.obj", "/b.usdz"])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("only .usda output") == true)
    }

    @Test func unsupportedInputFormatRefused() async {
        let result = await run(["convert", "/a.fbx", "/b.usda"])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("unsupported input format .fbx") == true)
    }

    @Test func missingInputIsRuntimeError() async {
        let result = await run(["convert", "/nonexistent/x.obj", "/tmp/x.usda"])
        #expect(result.code == 1)
        #expect(result.err.first?.hasPrefix("error:") == true)
    }

    @Test func diagnosticsGoToStderr() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLIConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("tex.obj")
        try Data("mtllib tex.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nusemtl M\nf 1 2 3\n".utf8).write(to: input)
        // Material references a texture that doesn't exist → warning diagnostic.
        try Data("newmtl M\nmap_Kd missing.png\n".utf8).write(to: dir.appendingPathComponent("tex.mtl"))
        let result = await run(["convert", input.path, dir.appendingPathComponent("out.usda").path])
        #expect(result.code == 0)
        #expect(result.err.contains { $0.hasPrefix("warning: [textures]") && $0.contains("could not be read") })
    }
}

// MARK: - convert-batch

@Suite("CLI convert-batch")
struct CLIConvertBatchTests {

    private func run(_ args: [String]) async -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = []
        var err: [String] = []
        let code = await CLIRunner.run(
            arguments: args, openStage: { _ in fixtureStage() },
            print: { out.append($0) }, printError: { err.append($0) })
        return (code, out, err)
    }

    /// A temp dir holding two OBJ triangles and a CSV manifest referencing them.
    private func makeWorkspace(manifest: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLIBatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
        try Data(obj.utf8).write(to: dir.appendingPathComponent("a.obj"))
        try Data(obj.utf8).write(to: dir.appendingPathComponent("b.obj"))
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.csv"))
        return dir
    }

    @Test func parsesManifestToleratingHeaderBlanksAndComments() {
        let rows = CLIRunner.parseManifest("""
        input,output
        a.glb, out/a.usda
        # a comment

        b.glb
        """)
        #expect(rows.count == 2)
        #expect(rows[0].input == "a.glb")
        #expect(rows[0].output == "out/a.usda")
        #expect(rows[1].input == "b.glb")
        #expect(rows[1].output == nil)
    }

    @Test func convertsAllRowsAndDefaultsOutputNextToInput() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\nb.obj\n")
        let result = await run(["convert-batch", dir.appendingPathComponent("manifest.csv").path])
        #expect(result.code == 0)
        #expect(result.out.last?.contains("2 ok, 0 failed") == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.usda").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.usda").path))
    }

    @Test func honorsOutDirAndExplicitOutputColumn() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\nb.obj,custom/bb.usda\n")
        let result = await run([
            "convert-batch", dir.appendingPathComponent("manifest.csv").path,
            "--out-dir", dir.appendingPathComponent("built").path,
        ])
        #expect(result.code == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("built/a.usda").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("custom/bb.usda").path))
    }

    @Test func failedRowGivesExitOneButOthersStillConvert() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\nmissing.obj\n")
        let result = await run(["convert-batch", dir.appendingPathComponent("manifest.csv").path])
        #expect(result.code == 1)
        #expect(result.out.contains { $0.contains("[FAIL]") })
        #expect(result.out.last?.contains("1 ok, 1 failed") == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.usda").path))
    }

    @Test func writesJSONReport() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\n")
        let reportURL = dir.appendingPathComponent("report.json")
        let result = await run([
            "convert-batch", dir.appendingPathComponent("manifest.csv").path,
            "--report", reportURL.path,
        ])
        #expect(result.code == 0)
        let data = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(BatchReport.self, from: data)
        #expect(report.succeededCount == 1)
    }

    @Test func writesCSVReport() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\n")
        let reportURL = dir.appendingPathComponent("report.csv")
        let result = await run([
            "convert-batch", dir.appendingPathComponent("manifest.csv").path,
            "--report", reportURL.path,
        ])
        #expect(result.code == 0)
        let csv = try String(contentsOf: reportURL, encoding: .utf8)
        #expect(csv.hasPrefix("input,output,status"))
    }

    @Test func noOverwriteSkipsExistingOutputs() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\n")
        try Data("stale".utf8).write(to: dir.appendingPathComponent("a.usda"))
        let result = await run([
            "convert-batch", dir.appendingPathComponent("manifest.csv").path, "--no-overwrite",
        ])
        #expect(result.code == 0)
        #expect(result.out.contains { $0.contains("[skip]") })
        #expect(try String(contentsOf: dir.appendingPathComponent("a.usda"), encoding: .utf8) == "stale")
    }

    @Test func missingManifestIsRuntimeError() async {
        let result = await run(["convert-batch", "/nonexistent/manifest.csv"])
        #expect(result.code == 1)
        #expect(result.err.first?.contains("could not read manifest") == true)
    }

    @Test func emptyManifestIsUsageError() async throws {
        let dir = try makeWorkspace(manifest: "# just a comment\n")
        let result = await run(["convert-batch", dir.appendingPathComponent("manifest.csv").path])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("no input rows") == true)
    }

    @Test func badReportExtensionIsUsageError() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\n")
        let result = await run([
            "convert-batch", dir.appendingPathComponent("manifest.csv").path, "--report", "out.txt",
        ])
        #expect(result.code == 2)
        #expect(result.err.first?.contains(".csv or .json") == true)
    }

    @Test func missingManifestArgumentIsUsageError() async {
        let result = await run(["convert-batch"])
        #expect(result.code == 2)
    }

    @Test func honorsPresetInterleavedWithOwnOptions() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\n")
        let result = await run([
            "convert-batch", dir.appendingPathComponent("manifest.csv").path,
            "--preset", "ecommerce", "--no-overwrite",
        ])
        #expect(result.code == 0)
    }

    @Test func unknownPresetIsUsageError() async throws {
        let dir = try makeWorkspace(manifest: "a.obj\n")
        let result = await run([
            "convert-batch", dir.appendingPathComponent("manifest.csv").path, "--preset", "bogus",
        ])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("unknown preset 'bogus'") == true)
    }
}

// MARK: - validate

@Suite("CLI validate")
struct CLIValidateTests {

    /// A stage that passes every ARKit-profile rule: real-world scale, a
    /// defaultPrim that resolves, and no problem meshes.
    private func compliantStage() -> StageSnapshot {
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform")
        return StageSnapshot(metadata: StageMetadata(metersPerUnit: 1.0, defaultPrim: "Car"), rootPrims: [car])
    }

    /// defaultPrim names a prim that does not exist → hard error.
    private func erroringStage() -> StageSnapshot {
        let car = Prim(path: PrimPath("/Car")!, typeName: "Xform")
        return StageSnapshot(metadata: StageMetadata(metersPerUnit: 1.0, defaultPrim: "Ghost"), rootPrims: [car])
    }

    private func run(_ args: [String], open: @escaping (URL) async throws -> any USDStageProtocol)
    async -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = []
        var err: [String] = []
        let code = await CLIRunner.run(
            arguments: args, openStage: open,
            print: { out.append($0) }, printError: { err.append($0) })
        return (code, out, err)
    }

    @Test func compliantStageExitsZero() async {
        let result = await run(["validate", "/tmp/ok.usdz"]) { _ in compliantStage() }
        #expect(result.code == 0)
        #expect(result.out.last?.contains("[arkit] 0 errors, 0 warnings, 0 info — export allowed") == true)
    }

    @Test func errorStageExitsOneAndPrintsDiagnostic() async {
        let result = await run(["validate", "/tmp/bad.usdz"]) { _ in erroringStage() }
        #expect(result.code == 1)
        let output = result.out.joined(separator: "\n")
        #expect(output.contains("error: [stage.defaultPrim]"))
        #expect(output.contains("export blocked"))
    }

    @Test func warningStageIsAllowedButStrictFails() async {
        // fixtureStage's Wheel mesh has no points → one warning, no errors.
        let lax = await run(["validate", "/tmp/warn.usdz"]) { _ in fixtureStage() }
        #expect(lax.code == 0)
        #expect(lax.out.contains { $0.contains("warning: [mesh.empty]") })
        #expect(lax.out.last?.contains("export allowed") == true)

        let strict = await run(["validate", "--strict", "/tmp/warn.usdz"]) { _ in fixtureStage() }
        #expect(strict.code == 1)
        #expect(strict.out.last?.contains("[arkit-strict]") == true)
        #expect(strict.out.last?.contains("export blocked") == true)
    }

    @Test func explicitStrictProfileMatchesStrictFlag() async {
        let result = await run(["validate", "--profile", "arkit-strict", "/tmp/warn.usdz"]) { _ in fixtureStage() }
        #expect(result.code == 1)
        #expect(result.out.last?.contains("[arkit-strict]") == true)
    }

    @Test func unknownProfileIsUsageError() async {
        let result = await run(["validate", "--profile", "bogus", "/tmp/warn.usdz"]) { _ in fixtureStage() }
        #expect(result.code == 2)
        #expect(result.err.contains { $0.contains("unknown profile 'bogus'") })
    }

    @Test func strictWithExplicitArkitProfileConflicts() async {
        let result = await run(["validate", "--profile", "arkit", "--strict", "/tmp/warn.usdz"]) { _ in fixtureStage() }
        #expect(result.code == 2)
        #expect(result.err.contains { $0.contains("conflicts") })
    }

    @Test func diagnosticLineIncludesPrimPath() async {
        let result = await run(["validate", "/tmp/warn.usdz"]) { _ in fixtureStage() }
        #expect(result.out.contains { $0.contains("(/Car/Wheel)") })
    }

    @Test func missingFileArgumentIsUsageError() async {
        let result = await run(["validate"]) { _ in fixtureStage() }
        #expect(result.code == 2)
        #expect(result.err.first?.contains("usage") == true)
    }

    @Test func unknownOptionIsUsageError() async {
        let result = await run(["validate", "--frob", "/tmp/x.usdz"]) { _ in fixtureStage() }
        #expect(result.code == 2)
        #expect(result.err.first?.contains("unknown option") == true)
    }

    @Test func openFailureIsRuntimeError() async {
        let result = await run(["validate", "/tmp/x.usdz"]) { _ in
            throw BridgeError.pythonUnavailable(detail: "nope")
        }
        #expect(result.code == 1)
        #expect(result.err.first?.contains("Python runtime unavailable") == true)
        #expect(result.err.count == 2)
    }

    // MARK: - The T1 CLI matrix: {valid, warning, invalid} × {default, --json, --strict}

    /// The three stage classes the gate has to separate, named so failures point
    /// straight at the row of the matrix that broke.
    enum StageClass: String, CaseIterable {
        case valid, warning, invalid
    }

    /// The three renderings/gates the matrix crosses those stages with.
    enum Mode: String, CaseIterable {
        case `default`, json, strict

        var flags: [String] {
            switch self {
            case .default: return []
            case .json: return ["--json"]
            case .strict: return ["--strict"]
            }
        }
    }

    private func stage(_ kind: StageClass) -> StageSnapshot {
        switch kind {
        case .valid: return compliantStage()
        case .warning: return fixtureStage()   // empty Wheel mesh → one warning
        case .invalid: return erroringStage()  // dangling defaultPrim → one error
        }
    }

    /// The expected exit code for each cell. A warning stage flips from allowed
    /// to blocked only under `--strict`; `--json` never changes a verdict.
    private func expectedCode(_ kind: StageClass, _ mode: Mode) -> Int32 {
        switch kind {
        case .valid: return 0
        case .invalid: return 1
        case .warning: return mode == .strict ? 1 : 0
        }
    }

    private func parseJSON(_ out: [String]) throws -> [String: Any] {
        let text = out.joined(separator: "\n")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    @Test(arguments: StageClass.allCases, Mode.allCases)
    func validateMatrixExitCode(kind: StageClass, mode: Mode) async {
        let snapshot = stage(kind)
        let result = await run(["validate"] + mode.flags + ["/tmp/\(kind.rawValue).usdz"]) { _ in snapshot }
        #expect(result.code == expectedCode(kind, mode),
                "\(kind.rawValue) × \(mode.rawValue) should exit \(expectedCode(kind, mode))")
        #expect(result.err.isEmpty)
    }

    @Test(arguments: StageClass.allCases)
    func jsonReportAgreesWithTheHumanRendering(kind: StageClass) async throws {
        let snapshot = stage(kind)
        let plain = await run(["validate", "/tmp/x.usdz"]) { _ in snapshot }
        let json = await run(["validate", "--json", "/tmp/x.usdz"]) { _ in snapshot }

        // Same verdict, two renderings.
        #expect(plain.code == json.code)

        let payload = try parseJSON(json.out)
        #expect(payload["file"] as? String == "/tmp/x.usdz")
        #expect(payload["profile"] as? String == "arkit")
        #expect(payload["blockingSeverity"] as? String == "error")
        #expect(payload["exportAllowed"] as? Bool == (json.code == 0))
        // The summary line is carried verbatim, so a script and a human agree.
        #expect(payload["summary"] as? String == plain.out.last)

        // One JSON diagnostic per printed diagnostic line, in the same order.
        let diagnostics = try #require(payload["diagnostics"] as? [[String: Any]])
        #expect(diagnostics.count == plain.out.count - 1)
        for (object, line) in zip(diagnostics, plain.out.dropLast()) {
            let ruleID = try #require(object["ruleID"] as? String)
            let severity = try #require(object["severity"] as? String)
            #expect(line.hasPrefix("\(severity): [\(ruleID)]"))
        }
    }

    @Test func jsonMarksExactlyTheBlockingDiagnostics() async throws {
        // A warning stage: nothing blocks by default…
        let lax = try await parseJSON(run(["validate", "--json", "/tmp/w.usdz"]) { _ in fixtureStage() }.out)
        let laxDiagnostics = try #require(lax["diagnostics"] as? [[String: Any]])
        #expect(laxDiagnostics.contains { $0["severity"] as? String == "warning" })
        #expect(laxDiagnostics.allSatisfy { $0["blocking"] as? Bool == false })
        #expect(lax["exportAllowed"] as? Bool == true)

        // …and the same warnings block once the strict gate is selected.
        let strict = try await parseJSON(
            run(["validate", "--json", "--strict", "/tmp/w.usdz"]) { _ in fixtureStage() }.out)
        let strictDiagnostics = try #require(strict["diagnostics"] as? [[String: Any]])
        #expect(strict["profile"] as? String == "arkit-strict")
        #expect(strict["blockingSeverity"] as? String == "warning")
        #expect(strict["exportAllowed"] as? Bool == false)
        for object in strictDiagnostics {
            let severity = try #require(object["severity"] as? String)
            #expect(object["blocking"] as? Bool == (severity != "info"))
        }
    }

    @Test func jsonCarriesPrimPathsAndOmitsThemWhenAbsent() async throws {
        let payload = try await parseJSON(
            run(["validate", "--json", "/tmp/w.usdz"]) { _ in fixtureStage() }.out)
        let diagnostics = try #require(payload["diagnostics"] as? [[String: Any]])

        // Prim-anchored diagnostics carry their path…
        #expect(diagnostics.contains { $0["primPath"] as? String == "/Car/Wheel" })

        // …and stage-level ones (no prim) omit the key rather than emitting
        // null, so consumers can treat presence as "this points at a prim".
        let stageLevel = try await parseJSON(
            run(["validate", "--json", "/tmp/bad.usdz"]) { _ in erroringStage() }.out)
        let stageDiagnostics = try #require(stageLevel["diagnostics"] as? [[String: Any]])
        let defaultPrim = try #require(
            stageDiagnostics.first { $0["ruleID"] as? String == "stage.defaultPrim" })
        #expect(defaultPrim["primPath"] == nil)
        #expect(defaultPrim["blocking"] as? Bool == true)
    }

    @Test func jsonIsValidForACleanStageWithNoDiagnostics() async throws {
        let payload = try await parseJSON(
            run(["validate", "--json", "/tmp/ok.usdz"]) { _ in compliantStage() }.out)
        #expect((payload["diagnostics"] as? [[String: Any]])?.isEmpty == true)
        #expect(payload["exportAllowed"] as? Bool == true)
    }

    @Test func jsonCombinesWithAnExplicitProfile() async throws {
        let payload = try await parseJSON(
            run(["validate", "--json", "--profile", "arkit-strict", "/tmp/w.usdz"]) { _ in fixtureStage() }.out)
        #expect(payload["profile"] as? String == "arkit-strict")
        #expect(payload["exportAllowed"] as? Bool == false)
    }

    @Test func jsonFlagDoesNotSuppressUsageErrors() async {
        // Argument errors are diagnostics about the invocation, not the model,
        // so they stay on stderr in plain text even under --json.
        let result = await run(["validate", "--json", "--profile", "bogus", "/tmp/x.usdz"]) { _ in fixtureStage() }
        #expect(result.code == 2)
        #expect(result.out.isEmpty)
        #expect(result.err.contains { $0.contains("unknown profile 'bogus'") })
    }
}

// MARK: - shared texture-policy options

@Suite("CLI texture presets")
struct CLIPolicyOverridesTests {

    private func resolve(_ overrides: CLIRunner.PolicyOverrides) -> TexturePolicy? {
        switch overrides.resolve(printError: { _ in }) {
        case .policy(let p): return p
        case .fail: return nil
        }
    }

    @Test func presetSuppliesBasePolicy() {
        var overrides = CLIRunner.PolicyOverrides()
        overrides.presetID = "ecommerce"
        let policy = resolve(overrides)
        #expect(policy?.maxSize == 1024)
        #expect(policy?.encodeBaseColorAsJPEG == true)
    }

    @Test func explicitFlagsOverridePreset() {
        // --max-texture-size wins over the ecommerce preset's 1024 regardless
        // of which knob the preset set.
        var overrides = CLIRunner.PolicyOverrides()
        overrides.presetID = "ecommerce"
        overrides.maxSize = 4096
        let policy = resolve(overrides)
        #expect(policy?.maxSize == 4096)
        #expect(policy?.encodeBaseColorAsJPEG == true)  // preset value retained
    }

    @Test func noPresetIsDefaultPolicy() {
        #expect(resolve(CLIRunner.PolicyOverrides()) == TexturePolicy())
    }

    @Test func unknownPresetFails() {
        var overrides = CLIRunner.PolicyOverrides()
        overrides.presetID = "nope"
        #expect(resolve(overrides) == nil)
    }

    @Test func presetWithoutNameIsError() {
        var overrides = CLIRunner.PolicyOverrides()
        var positional: [String] = []
        let outcome = overrides.parse(&positional, arguments: ["--preset"], printError: { _ in })
        if case .fail(let code) = outcome { #expect(code == 2) } else { Issue.record("expected failure") }
    }
}
