import Testing
import Foundation
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
