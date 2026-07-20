import SwiftUI
import DicyaninDesignSystem

/// Status of a single agent tool call in the activity feed.
public enum MCPCallStatus: Sendable, Equatable {
    case running
    case success
    case error
}

/// One row in the MCP activity panel — a single tool call. Identified by
/// `(pid, seq)` so calls from two concurrent servers never collide.
public struct MCPCallRow: Identifiable, Sendable, Equatable {
    public let pid: Int
    public let seq: Int
    public var tool: String
    public var status: MCPCallStatus
    public var durationMs: Int?
    public var summary: String

    public var id: String { "\(pid)-\(seq)" }

    public init(pid: Int, seq: Int, tool: String, status: MCPCallStatus,
                durationMs: Int? = nil, summary: String = "") {
        self.pid = pid
        self.seq = seq
        self.tool = tool
        self.status = status
        self.durationMs = durationMs
        self.summary = summary
    }
}

/// Presentational state for the MCP activity panel + menu-bar tray. Lives in
/// EditorUI (which the app may depend on) so the panel can observe it, while the
/// cross-process wire decoding stays in the app target — dependency-lint forbids
/// EditorUI from importing AgentMCP. The app owns an instance and updates it;
/// the shell receives it as a plain value and observes it inside the panel.
@MainActor
public final class MCPActivityModel: ObservableObject {
    /// A live server is connected and pushing events.
    @Published public var isConnected = false
    /// File the connected server is serving (nil when disconnected).
    @Published public var servedFile: String?
    /// Number of tools the connected server exposes.
    @Published public var toolCount = 0
    /// Enabled tool groups of the connected server.
    @Published public var groups: [String] = []
    /// When the current session connected (for uptime display).
    @Published public var connectedSince: Date?
    /// Most-recent-first list of tool calls (bounded ring buffer).
    @Published public var rows: [MCPCallRow] = []

    /// Number of calls still running.
    public var runningCount: Int { rows.lazy.filter { $0.status == .running }.count }

    public init() {}
}

/// The collapsible activity drawer, mirroring `ValidationDrawer`. Shown in the
/// editor's center column while an MCP session is connected.
struct MCPActivityPanel: View {
    @ObservedObject var model: MCPActivityModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Agent Activity", systemImage: "sparkles") {
                HStack(spacing: Spacing.xs) {
                    if let file = model.servedFile {
                        StatusPill(text: file,
                                   tint: model.isConnected ? Palette.success : Palette.textTertiary)
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: TypeScale.label, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary.color)
                }
            }
            if model.rows.isEmpty {
                emptyState
            } else {
                List(model.rows) { row in
                    MCPCallRowView(row: row)
                        .listRowBackground(Palette.panelBackground.color)
                        .listRowSeparatorTint(Palette.borderSubtle.color)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.panelBackground.color)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.xs) {
            Spacer(minLength: 0)
            Text(model.isConnected
                 ? "Waiting for the agent's first tool call…"
                 : "No agent connected.")
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textTertiary.color)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A single tool-call row: status glyph, tool name, duration, and summary.
struct MCPCallRowView: View {
    let row: MCPCallRow

    var body: some View {
        HStack(spacing: Spacing.xs) {
            glyph
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.xs) {
                    Text(row.tool)
                        .font(.system(size: TypeScale.body, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary.color)
                    if let ms = row.durationMs {
                        Text("\(ms) ms")
                            .font(.system(size: TypeScale.caption, design: .monospaced))
                            .foregroundStyle(Palette.textTertiary.color)
                    }
                }
                if !row.summary.isEmpty {
                    Text(row.summary)
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var glyph: some View {
        switch row.status {
        case .running:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.success.color)
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Palette.error.color)
        }
    }
}

/// Action-bar accessory: a connection dot + a toggle for the activity drawer.
/// Observes the model so it can auto-reveal the drawer when a server connects.
struct MCPStatusAccessory: View {
    @ObservedObject var model: MCPActivityModel
    @Binding var showActivity: Bool

    var body: some View {
        Button {
            showActivity.toggle()
        } label: {
            Label {
                Text(labelText)
            } icon: {
                Circle()
                    .fill((model.isConnected ? Palette.success : Palette.textTertiary).color)
                    .frame(width: 7, height: 7)
            }
        }
        .buttonStyle(ToolbarButtonStyle(isActive: showActivity))
        .help(model.isConnected ? "Agent connected — show activity" : "No agent connected")
        .onChange(of: model.isConnected) { _, connected in
            if connected { showActivity = true }
        }
    }

    private var labelText: String {
        if !model.isConnected { return "Agent" }
        let running = model.runningCount
        return running > 0 ? "Agent · \(running) running" : "Agent"
    }
}
