import AgentMCP
import Foundation
import Testing
@testable import openusdz

@Suite struct McpCommandTests {

    private func resolve(_ arguments: [String]) -> (McpCommand.Resolution?, String) {
        var errors: [String] = []
        let resolution = McpCommand.resolve(arguments: arguments) { errors.append($0) }
        return (resolution, errors.joined(separator: "\n"))
    }

    @Test func defaultsToFullSurface() {
        let (resolution, _) = resolve(["scene.usdz"])
        #expect(resolution?.fileURL.lastPathComponent == "scene.usdz")
        #expect(resolution?.groups == Set(ToolGroup.allCases))
        #expect(resolution?.strictness == .warn)
        #expect(resolution?.libraryDirectories.isEmpty == true)
        // Relaying to a live editor is the default; opt out explicitly.
        #expect(resolution?.noRelay == false)
    }

    @Test func parsesNoRelay() {
        let (resolution, _) = resolve(["scene.usda", "--no-relay"])
        #expect(resolution?.noRelay == true)
        #expect(resolution?.fileURL.lastPathComponent == "scene.usda")
    }

    @Test func parsesGroupsStrictnessAndLibraries() {
        let (resolution, _) = resolve([
            "scene.usda",
            "--groups", "read,verify",
            "--strictness", "strict",
            "--library", "/assets/a",
            "--library", "/assets/b",
        ])
        #expect(resolution?.groups == [.read, .verify])
        #expect(resolution?.strictness == .strict)
        #expect(resolution?.libraryDirectories.map(\.path) == ["/assets/a", "/assets/b"])
    }

    @Test func usageErrors() {
        #expect(resolve([]).0 == nil)
        #expect(resolve(["a.usdz", "b.usdz"]).0 == nil)
        let (badGroup, message) = resolve(["scene.usdz", "--groups", "read,wizardry"])
        #expect(badGroup == nil)
        #expect(message.contains("unknown tool group"))
        #expect(resolve(["scene.usdz", "--groups"]).0 == nil)
        #expect(resolve(["scene.usdz", "--groups", ""]).0 == nil)
        #expect(resolve(["scene.usdz", "--strictness", "pedantic"]).0 == nil)
        #expect(resolve(["scene.usdz", "--strictness"]).0 == nil)
        #expect(resolve(["scene.usdz", "--library"]).0 == nil)
        let (unknown, unknownMessage) = resolve(["scene.usdz", "--frobnicate"])
        #expect(unknown == nil)
        #expect(unknownMessage.contains("unknown option"))
    }

    @Test func mcpSubcommandUsageExitCode() async {
        var errors: [String] = []
        let code = await CLIRunner.run(
            arguments: ["mcp"],
            print: { _ in },
            printError: { errors.append($0) })
        #expect(code == 2)
        #expect(errors.joined().contains("usage: openusdz mcp"))
    }
}
