import Testing
import Foundation
import USDCore
@testable import openusdz

/// Closes CLI coverage gaps: argument-parse error branches across subcommands,
/// dispatch to build/thumbnail, and BuildCommand's default (real-file) IO
/// closures. Real-subprocess launch paths are excluded at the source with
/// coverage:disable/enable regions (specs/testing.md exclusion discipline).
@Suite("CLI coverage closure")
struct CLICoverageClosureTests {

    // Uses ALL defaults (print/printError/openStage) — exercises the default
    // parameter expressions — and returns before any stage open.
    @Test func unknownSubcommandViaDefaultsReturnsUsageError() async {
        let code = await CLIRunner.run(arguments: ["frobnicate"])
        #expect(code == 2)
    }

    @Test func convertBatchArgumentErrors() async {
        func run(_ args: [String]) async -> Int32 {
            await CLIRunner.run(arguments: args, openStage: { _ in StageSnapshot() },
                                print: { _ in }, printError: { _ in })
        }
        #expect(await run(["convert-batch", "--out-dir"]) == 2)     // needs a path
        #expect(await run(["convert-batch", "--report"]) == 2)      // needs a path
        #expect(await run(["convert-batch", "--bogus"]) == 2)       // unknown option
    }

    @Test func validateProfileNeedsName() async {
        let code = await CLIRunner.run(
            arguments: ["validate", "/tmp/x.usdz", "--profile"],
            openStage: { _ in StageSnapshot() }, print: { _ in }, printError: { _ in })
        #expect(code == 2)
    }

    @Test func dispatchesToBuildAndThumbnail() async {
        // Bad args make each subcommand return before doing real work, but the
        // dispatch arms in CLIRunner.run are covered.
        let build = await CLIRunner.run(arguments: ["build"], print: { _ in }, printError: { _ in })
        #expect(build == 2)
        let thumb = await CLIRunner.run(arguments: ["thumbnail", "--out"],
                                        print: { _ in }, printError: { _ in })
        #expect(thumb == 2)
    }

    // MARK: BuildCommand default IO closures + generic catch

    private func tempFile(_ text: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func buildWithDefaultIOClosuresWritesRealFile() throws {
        let recipe = #"{"name":"C","materials":[],"parts":[{"name":"P","primitive":{"type":"box","size":[1,1,1]},"steps":[]}]}"#
        let recipeURL = try tempFile(recipe, ext: "json")
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(UUID().uuidString).usda")
        defer { try? FileManager.default.removeItem(at: outURL) }

        // No writeFile/readFile injected → default real-file closures run.
        let code = BuildCommand.run(
            arguments: [recipeURL.path, outURL.path], print: { _ in }, printError: { _ in })
        #expect(code == 0)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
    }

    @Test func convertBatchReportWriteFailureReturnsError() async throws {
        // One-row manifest (bad input → failed job) then a report path in a
        // directory that doesn't exist, so the report write throws.
        let manifest = try tempFile("nonexistent-input.glb\n", ext: "csv")
        let unwritable = "/no/such/dir/report-\(UUID().uuidString).json"
        let code = await CLIRunner.run(
            arguments: ["convert-batch", manifest.path, "--report", unwritable],
            openStage: { _ in StageSnapshot() }, print: { _ in }, printError: { _ in })
        #expect(code == 1)
    }

    @Test func infoSuccessUsesDefaultPrintClosure() async {
        let stage = StageSnapshot(
            metadata: StageMetadata(defaultPrim: "Root"),
            rootPrims: [Prim(path: PrimPath("/Root")!, typeName: "Xform")])
        // openStage injected, but print/printError use their defaults (real
        // stdout/stderr) — exercises the default print closure body on success.
        let code = await CLIRunner.run(arguments: ["info", "/tmp/x.usdz"],
                                       openStage: { _ in stage })
        #expect(code == 0)
    }

    @Test func buildWithMalformedRecipeHitsGenericCatch() throws {
        let recipeURL = try tempFile("{ not valid json ", ext: "json")
        var errs: [String] = []
        let code = BuildCommand.run(
            arguments: [recipeURL.path, "/tmp/out-\(UUID().uuidString).usda"],
            print: { _ in }, printError: { errs.append($0) })
        #expect(code == 1)
        #expect(errs.contains { $0.hasPrefix("error:") })
    }
}
