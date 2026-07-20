import AppKit
import EditorUI
import SwiftUI

/// The menu-bar icon, tinted by live connection state. A dedicated view so it
/// re-renders when the model changes.
struct MCPMenuBarLabel: View {
    @ObservedObject var model: MCPActivityModel

    var body: some View {
        Image(systemName: model.isConnected
              ? "sparkles.square.filled.on.square"
              : "square.on.square.dashed")
    }
}

/// Menu-bar (tray) content for the MCP server: live connection status plus
/// copy-paste setup commands, so a user can wire `openusdz mcp` into their MCP
/// client without leaving the app.
struct MCPMenuBarContent: View {
    @ObservedObject var model: MCPActivityModel
    /// Path of the currently open document, used to build example commands.
    var documentPath: String?

    private var fileArg: String { documentPath ?? "<file.usdz>" }
    private var serveCommand: String { "openusdz mcp \(shellQuote(fileArg))" }
    private var registerCommand: String {
        "claude mcp add openusdz -- openusdz mcp \(shellQuote(fileArg))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            Divider()
            if model.isConnected {
                if let file = model.servedFile {
                    labeled("Serving", file)
                }
                labeled("Tools", "\(model.toolCount)")
                if !model.groups.isEmpty {
                    labeled("Groups", model.groups.joined(separator: ", "))
                }
                if model.runningCount > 0 {
                    labeled("Running", "\(model.runningCount) call(s)")
                }
                Divider()
            }

            Text("Setup").font(.caption).foregroundStyle(.secondary)
            commandRow("Serve this file", serveCommand)
            commandRow("Register with Claude Code", registerCommand)

            Divider()
            Button("Open MCP Design Doc") { openDoc() }
            Button("Quit OpenUSDZ Editor") { NSApplication.shared.terminate(nil) }
        }
        .padding(10)
        .frame(width: 320)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.isConnected ? "Agent connected" : "No agent connected")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }

    private func commandRow(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    copy(command)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func openDoc() {
        // Best-effort: open the design doc from the repo when running the dev build.
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("docs/AGENT_MCP_PLAN.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                NSWorkspace.shared.open(candidate)
                return
            }
            dir.deleteLastPathComponent()
        }
    }

    private func shellQuote(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
