import Foundation
import ScriptingKit
import USDCore

/// Assembles the full MCP server over one `EditSession`: every tool group,
/// the read-only resources, and the workflow-recipe prompts
/// (docs/AGENT_MCP_PLAN.md §2 — the server is a thin adapter; no editing
/// logic lives here).
public enum AgentMCPServer {

    public struct Configuration: Sendable {
        public var enabledGroups: Set<ToolGroup>
        public var renderer: (any RenderExecuting)?
        public var scriptExecutor: (any ScriptExecuting)?
        public var generators: [any AssetGenerating]
        public var libraryDirectories: [URL]
        public var workDirectory: URL
        /// Optional live-activity observer for the app's MCP activity panel.
        public var eventSink: (any MCPEventSink)?
        /// Whether this session's stage is visible anywhere (app-hosted) or
        /// headless (the CLI server) — surfaced via `capabilities` and used by
        /// `open_in_app` so agents can reveal results to the user (issue #162).
        public var stageAttachment: AppTools.StageAttachment
        /// How `open_in_app` reveals a saved snapshot; nil uses `/usr/bin/open`.
        /// Injectable for tests and for the app host (which brings its own
        /// document to the front instead of shelling out).
        public var appOpener: AppTools.Opener?

        public init(
            enabledGroups: Set<ToolGroup> = Set(ToolGroup.allCases),
            renderer: (any RenderExecuting)? = nil,
            scriptExecutor: (any ScriptExecuting)? = nil,
            generators: [any AssetGenerating] = [],
            libraryDirectories: [URL] = [],
            workDirectory: URL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openusdz-agent", isDirectory: true),
            eventSink: (any MCPEventSink)? = nil,
            stageAttachment: AppTools.StageAttachment = .headless,
            appOpener: AppTools.Opener? = nil
        ) {
            self.enabledGroups = enabledGroups
            self.renderer = renderer
            self.scriptExecutor = scriptExecutor
            self.generators = generators
            self.libraryDirectories = libraryDirectories
            self.workDirectory = workDirectory
            self.eventSink = eventSink
            self.stageAttachment = stageAttachment
            self.appOpener = appOpener
        }
    }

    /// Build a fully-registered server for a session.
    public static func make(session: EditSession, configuration: Configuration = Configuration()) -> MCPServer {
        let server = MCPServer(
            enabledGroups: configuration.enabledGroups,
            eventSink: configuration.eventSink)

        // The sculpt store is shared with the verify tools so the `score`
        // spatial gate can honor the active spec's declared attachments (#161).
        let sculptStore = SculptStore(workDirectory: configuration.workDirectory)

        ReadTools.register(on: server, session: session)
        MutateTools.register(on: server, session: session)
        JointTools.register(on: server, session: session)
        VerifyTools.register(on: server, session: session, sculptStore: sculptStore)
        RenderTools.register(
            on: server, session: session,
            renderer: configuration.renderer,
            workDirectory: configuration.workDirectory)
        AssetTools.register(
            on: server, session: session,
            generators: configuration.generators,
            libraryDirectories: configuration.libraryDirectories,
            jobs: AssetJobStore())
        ReferenceImageTools.register(on: server, session: session)
        TransactionTools.register(on: server, session: session)
        ScriptTools.register(
            on: server, session: session,
            executor: configuration.scriptExecutor,
            workDirectory: configuration.workDirectory)
        SculptTools.register(
            on: server, session: session,
            store: sculptStore,
            workDirectory: configuration.workDirectory)
        RigTools.register(
            on: server, session: session,
            store: RigStore(workDirectory: configuration.workDirectory),
            workDirectory: configuration.workDirectory)
        AppTools.register(
            on: server, session: session,
            workDirectory: configuration.workDirectory,
            attachment: configuration.stageAttachment,
            opener: configuration.appOpener ?? AppTools.systemOpener)

        // §3.1 — the same payloads as read tools, exposed as MCP resources so
        // clients that support resources get state readback without burning
        // tool calls.
        server.register(MCPResource(
            uri: "usd://scene", name: "Scene description",
            description: "Compact typed snapshot: hierarchy outline, stats, bindings."
        ) { ReadTools.describe(session: session, maxDepth: 4) })
        server.register(MCPResource(
            uri: "usd://stats", name: "Scene stats",
            description: "Prim/mesh/triangle counts, bounds, up axis, metersPerUnit."
        ) { ReadTools.stats(session: session) })
        server.register(MCPResource(
            uri: "usd://history", name: "Edit history",
            description: "Undo depth and the current undo/redo labels."
        ) {
            .object([
                "undoDepth": .number(Double(session.stack.undoCount)),
                "canUndo": .bool(session.stack.canUndo),
                "canRedo": .bool(session.stack.canRedo),
                "undoLabel": session.stack.undoLabel.map { .string($0) } ?? .null,
                "redoLabel": session.stack.redoLabel.map { .string($0) } ?? .null,
            ])
        })

        server.register(MCPResource(
            uri: "usd://reference", name: "Reference image",
            description: "The reference image the agent is working from (path + caption), or null."
        ) { session.referenceImage?.asJSON ?? .null })

        WorkflowPrompts.register(on: server)
        server.instructions = AgentInstructions.text

        // Announce the session to any attached activity observer, now that the
        // full tool set is registered (so toolCount/groups are final).
        server.announceSession(
            servedFile: session.sourceURL?.lastPathComponent ?? "untitled",
            groups: configuration.enabledGroups.map(\.rawValue).sorted())
        return server
    }
}
