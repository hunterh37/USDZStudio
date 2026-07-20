import Testing
import SwiftUI
@testable import EditorUI

/// Exercises the MCP activity view builders. Accessing `body` runs the
/// ViewBuilder closures (empty vs populated states, every status glyph, the
/// accessory label), which unit tests can drive without a rendering host.
@MainActor
@Suite struct MCPActivityPanelViewTests {

    @Test func panelBodyRendersDisconnectedEmptyState() {
        let model = MCPActivityModel()
        let panel = MCPActivityPanel(model: model, onClose: {})
        _ = panel.body
    }

    @Test func panelBodyRendersConnectedWithRows() {
        let model = MCPActivityModel()
        model.isConnected = true
        model.servedFile = "scene.usda"
        model.rows = [
            MCPCallRow(pid: 1, seq: 1, tool: "create_prim", status: .running),
            MCPCallRow(pid: 1, seq: 2, tool: "set_attribute", status: .success,
                       durationMs: 4, summary: "ok"),
        ]
        let panel = MCPActivityPanel(model: model, onClose: {})
        _ = panel.body
    }

    @Test func callRowBodyCoversEveryGlyphAndDetail() {
        let rows = [
            MCPCallRow(pid: 1, seq: 1, tool: "a", status: .running),
            MCPCallRow(pid: 1, seq: 2, tool: "b", status: .success,
                       durationMs: 12, summary: "done"),
            MCPCallRow(pid: 1, seq: 3, tool: "c", status: .error, summary: "boom"),
        ]
        for row in rows {
            _ = MCPCallRowView(row: row).body
        }
    }

    @Test func statusAccessoryBodyCoversLabelBranches() {
        // Disconnected → "Agent".
        let idle = MCPActivityModel()
        _ = MCPStatusAccessory(model: idle, showActivity: .constant(false)).body

        // Connected with running calls → "Agent · N running".
        let busy = MCPActivityModel()
        busy.isConnected = true
        busy.rows = [MCPCallRow(pid: 1, seq: 1, tool: "x", status: .running)]
        _ = MCPStatusAccessory(model: busy, showActivity: .constant(true)).body
    }
}
