import Testing
import Foundation
import ConversionKit
import USDCore
import USDBridge
@testable import dicyanin_usdz

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
