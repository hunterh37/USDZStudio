import AgentMCP
import Foundation
import Testing
@testable import openusdz

/// The shared MCP support-directory locations, including the reference-image
/// hand-off file the CLI persists for a later-launched editor
/// (specs/agent-live-editing.md — "Reference panel").
@Suite struct MCPActivityPathsTests {

    @Test func referenceFileSitsBesideEndpointAndSocket() {
        let dir = MCPActivityPaths.mcpDirectory()
        let reference = MCPActivityPaths.referenceURL()
        #expect(reference.lastPathComponent == "reference.json")
        #expect(reference.deletingLastPathComponent() == dir)
        // Same directory as the discovery file + socket the editor already uses.
        #expect(MCPActivityPaths.endpointURL().deletingLastPathComponent() == dir)
        #expect(MCPActivityPaths.socketURL().deletingLastPathComponent() == dir)
    }

    @Test func referenceRecordRoundTripsAtThatLocation() throws {
        // The CLI writes an AgentMCP `ReferenceImage` here; the app reads it back.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ref-\(UUID().uuidString)/reference.json")
        let record = ReferenceImage(path: "/tmp/robot.png", caption: "hero")
        try record.write(to: url)
        #expect(ReferenceImage.read(from: url) == record)
        ReferenceImage.remove(at: url)
        #expect(ReferenceImage.read(from: url) == nil)
    }
}
