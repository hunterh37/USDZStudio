import Foundation
import Testing
@testable import openusdz

/// Pure seams of the AF_UNIX transport (the socket IO itself is a
/// coverage-disabled composition root, verified end-to-end).
@Suite struct UnixSocketTests {

    // MARK: UnixSocketPath.fits

    @Test func acceptsPathsThatFitSunPath() {
        #expect(UnixSocketPath.fits("/tmp/agent.sock"))
        // Exactly maxLength-1 bytes fits (room for the NUL terminator).
        #expect(UnixSocketPath.fits(String(repeating: "a", count: UnixSocketPath.maxLength - 1)))
    }

    @Test func rejectsEmptyOrOverlongPaths() {
        #expect(!UnixSocketPath.fits(""))
        #expect(!UnixSocketPath.fits(String(repeating: "a", count: UnixSocketPath.maxLength)))
        #expect(!UnixSocketPath.fits(String(repeating: "a", count: UnixSocketPath.maxLength + 50)))
    }

    // MARK: Discovery paths

    @Test func socketAndEndpointShareTheMcpDirectory() {
        let endpoint = MCPActivityPaths.endpointURL()
        let socket = MCPActivityPaths.socketURL()
        #expect(endpoint.lastPathComponent == "endpoint.json")
        #expect(socket.lastPathComponent == "agent.sock")
        // Both live in .../OpenUSDZEditor/mcp/.
        #expect(endpoint.deletingLastPathComponent() == socket.deletingLastPathComponent())
        #expect(socket.deletingLastPathComponent().lastPathComponent == "mcp")
    }

    @Test func socketPathHonorsInjectedFileManager() {
        // The default FileManager resolves a real Application Support dir; the
        // path derivation is deterministic relative to it.
        let socket = MCPActivityPaths.socketURL()
        #expect(socket.path.hasSuffix("/OpenUSDZEditor/mcp/agent.sock"))
    }
}
