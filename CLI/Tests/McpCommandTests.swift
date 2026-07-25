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
        // Visible by default: auto-launch is on unless --headless.
        #expect(resolution?.headless == false)
    }

    /// #166 was filed as "the CLI-hosted MCP server never wires a renderer, so
    /// render_views is stats-only". It was actually a stale binary — but nobody
    /// could *prove* the wiring without spawning a process and reading JSON,
    /// which is why the report was plausible. These assert the composition root
    /// directly, so a genuine regression fails in CI instead of turning into a
    /// field bug hunt.
    @Test func configurationAlwaysWiresARenderer() {
        let (resolution, _) = resolve(["scene.usdz"])
        let configuration = McpCommand.makeConfiguration(
            resolution: resolution!, eventSink: nil,
            environment: [:], fileExists: { _ in false }, pythonPath: nil)
        // The native renderer needs no usdrecord and no Python, so a bare
        // environment must still yield real pixels.
        #expect(configuration.renderer != nil)
        #expect(configuration.enabledGroups == Set(ToolGroup.allCases))
        // No Python located → no script executor, but that must not take the
        // renderer down with it.
        #expect(configuration.scriptExecutor == nil)
    }

    /// The renderer survives a narrowed tool surface and custom libraries, and
    /// a located Python adds the script executor without disturbing it.
    @Test func configurationCarriesResolutionAndPython() {
        let (resolution, _) = resolve(["scene.usda", "--groups", "render", "--library", "/tmp/lib"])
        let configuration = McpCommand.makeConfiguration(
            resolution: resolution!, eventSink: nil,
            environment: [:], fileExists: { _ in false }, pythonPath: "/usr/bin/python3")
        #expect(configuration.renderer != nil)
        #expect(configuration.enabledGroups == [.render])
        #expect(configuration.scriptExecutor != nil)
        #expect(configuration.libraryDirectories.map(\.path) == ["/tmp/lib"])
    }

    @Test func parsesNoRelay() {
        let (resolution, _) = resolve(["scene.usda", "--no-relay"])
        #expect(resolution?.noRelay == true)
        #expect(resolution?.fileURL.lastPathComponent == "scene.usda")
    }

    @Test func parsesHeadless() {
        let (resolution, _) = resolve(["scene.usda", "--headless"])
        #expect(resolution?.headless == true)
        // --headless is independent of --no-relay.
        #expect(resolution?.noRelay == false)
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
