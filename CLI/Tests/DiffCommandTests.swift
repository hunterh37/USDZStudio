import Testing
import Foundation
import USDCore
import USDBridge
@testable import openusdz

@Suite("openusdz diff")
struct DiffCommandTests {

    private func stage(_ prims: [Prim], metadata: StageMetadata = StageMetadata()) -> StageSnapshot {
        StageSnapshot(metadata: metadata, rootPrims: prims)
    }

    /// Opens by file name so a test can return a different stage per path.
    private func run(
        _ args: [String],
        files: [String: StageSnapshot] = [:],
        open: ((URL) async throws -> any USDStageProtocol)? = nil
    ) async -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = []
        var err: [String] = []
        let opener: (URL) async throws -> any USDStageProtocol = open ?? { url in
            guard let s = files[url.lastPathComponent] else { throw CocoaError(.fileNoSuchFile) }
            return s
        }
        let code = await DiffCommand.run(
            arguments: args, openStage: opener,
            print: { out.append($0) }, printError: { err.append($0) })
        return (code, out, err)
    }

    @Test func unknownOptionIsUsageError() async {
        let result = await run(["--nope", "a", "b"])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("unknown option") == true)
    }

    @Test func wrongArgumentCountIsUsageError() async {
        let result = await run(["only-one"])
        #expect(result.code == 2)
        #expect(result.err.first?.contains("exactly two files") == true)
    }

    @Test func openFailureReturnsTrouble() async {
        let result = await run(["a.usda", "b.usda"], open: { _ in throw CocoaError(.fileNoSuchFile) })
        #expect(result.code == 2)
        #expect(result.err.first?.contains("error:") == true)
    }

    @Test func bridgeErrorSurfacesSuggestion() async {
        let result = await run(["a.usda", "b.usda"], open: { _ in
            throw BridgeError.pythonUnavailable(detail: "no interpreter")
        })
        #expect(result.code == 2)
        #expect(result.err.contains { $0.contains("error:") })
    }

    @Test func identicalStagesExitZero() async {
        let s = stage([Prim(path: PrimPath("/Root")!, typeName: "Xform")])
        let result = await run(["a.usda", "b.usda"], files: ["a.usda": s, "b.usda": s])
        #expect(result.code == 0)
        #expect(result.out.joined().contains("identical"))
    }

    @Test func differingStagesExitOneWithReport() async {
        let before = stage([Prim(path: PrimPath("/Old")!, typeName: "Mesh")])
        let after = stage([Prim(path: PrimPath("/New")!, typeName: "Xform")])
        let result = await run(["a.usda", "b.usda"], files: ["a.usda": before, "b.usda": after])
        #expect(result.code == 1)
        let text = result.out.joined(separator: "\n")
        #expect(text.contains("Added prims"))
        #expect(text.contains("Removed prims"))
    }

    @Test func jsonOutputIsMachineReadable() async throws {
        let before = stage([Prim(path: PrimPath("/P")!, typeName: "Mesh")])
        let after = stage([Prim(path: PrimPath("/P")!, typeName: "Xform")])
        let result = await run(["--json", "a.usda", "b.usda"],
                               files: ["a.usda": before, "b.usda": after])
        #expect(result.code == 1)
        let json = result.out.joined(separator: "\n")
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["identical"] as? Bool == false)
        #expect(object?["before"] as? String == "a.usda")
        #expect(object?["diff"] != nil)
    }
}
