import Foundation
import SculptKit

/// Server self-description + app hand-off tools.
///
/// `capabilities` (issue #155): a deployed MCP binary can lag the repo source,
/// and agents following current docs then burn author→error→rewrite cycles
/// discovering the wire dialect by trial and error. This tool lets an agent
/// detect the deployed schema revision and op set up front.
///
/// `open_in_app` (issue #162): the CLI-hosted server edits a *headless* stage —
/// nothing the agent builds is visible anywhere until it is saved and opened.
/// Users reasonably assume the agent is driving a visible window, so agents
/// need a first-class way to reveal the current stage in the GUI editor (or
/// QuickLook) and to know, from the capabilities payload, whether the session
/// is headless or app-hosted.
public enum AppTools {

    /// Monotonic schema revision of the agent-facing wire formats. Bump when a
    /// tool's wire contract changes (ShapeKind coding, refinement kinds, …) so
    /// agents can detect a stale deployed binary (issue #155).
    public static let schemaRevision = 3

    /// How the hosting process attached this session to a user-visible surface.
    public enum StageAttachment: String, Sendable {
        /// No window anywhere shows this stage; edits are invisible until
        /// saved + opened (the CLI `mcp` server's mode).
        case headless
        /// The session shares the open document's stage — every edit is live
        /// in the app viewport (the app-hosted mode).
        case appHosted = "app-hosted"
    }

    /// Opens a saved snapshot in the GUI so the user can see the stage.
    /// Injectable so tests never launch anything; the default shells out to
    /// `/usr/bin/open` (Finder-default app for the file type, or `-a <app>`).
    public typealias Opener = @Sendable (_ url: URL, _ appName: String?) throws -> Void

    public static let systemOpener: Opener = { url, appName in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (appName.map { ["-a", $0] } ?? []) + [url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // coverage:disable — /usr/bin/open is present on every macOS install; failure here is environmental.
            throw ToolError.failed("could not launch open: \(error)")
            // coverage:enable
        }
        // coverage:disable — the success continuation requires actually launching the user's GUI via /usr/bin/open; the failure path is exercised with a missing file, and all tool logic is tested through injected openers.
        guard process.terminationStatus == 0 else {
            throw ToolError.failed("open exited with status \(process.terminationStatus) for \(url.path)")
        }
    }
    // coverage:enable

    public static func register(
        on server: MCPServer, session: EditSession,
        workDirectory: URL,
        attachment: StageAttachment = .headless,
        opener: @escaping Opener = systemOpener
    ) {
        server.register(MCPTool(
            name: "capabilities", group: .read,
            description: "Report what THIS deployed server build supports: the wire-schema revision, the sculpt spec dialect (friendly kind-keyed ShapeKind), the executable refinement op kinds, and whether the stage is headless or live in the app. Call this first when authoring sculpt specs or after any unexpected decode error — it detects a deployed binary that lags the documentation.",
            inputSchema: Schema.object([:])
        ) { _ in
            .object([
                "schemaRevision": .number(Double(schemaRevision)),
                "stageAttachment": .string(attachment.rawValue),
                "sculpt": .object([
                    // The friendly wire form (#112) plus Swift's synthesized
                    // enum coding are BOTH accepted; the friendly form is the
                    // documented one.
                    "shapeKindWireForm": .string(
                        "{\"kind\":\"group\"} | {\"kind\":\"primitive\",\"primitive\":\"box|plane|cylinder|cone|sphere\"} | {\"kind\":\"library\",\"entryID\":\"…\"}"),
                    "refinementKinds": .array(MeshRefinement.supportedKindNames.map { .string($0) }),
                ]),
                "toolGroups": .array(server.enabledGroups.map(\.rawValue).sorted().map { .string($0) }),
            ])
        })

        server.register(MCPTool(
            name: "open_in_app", group: .render,
            description: "Reveal the CURRENT stage to the user: saves a snapshot (usdz when the bridge is available, else usda) into the work directory — or to 'url' — and opens it on the user's machine (default app for the type, or 'app' to name one, e.g. 'USDZ Studio' or 'Preview'). Use this whenever the user asks to SEE the result or to 'launch the app': on a headless session (see `capabilities`) nothing is visible until this runs. Note the opened file is a snapshot — later edits need another open_in_app (or save + reopen) to be seen.",
            inputSchema: Schema.object([
                "url": Schema.string("destination file path for the snapshot (optional; default <workDirectory>/live-preview.usda|usdz)"),
                "app": Schema.string("application name to open with (optional; default the system handler for the file type)"),
            ])
        ) { args in
            let destination: URL
            if let raw = args["url"].stringValue {
                destination = URL(fileURLWithPath: raw)
            } else {
                // usdz needs the Python bridge; fall back to usda otherwise.
                let ext = session.saveExecutor != nil ? "usdz" : "usda"
                try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                destination = workDirectory.appendingPathComponent("live-preview.\(ext)")
            }
            let saved = try await session.save(to: destination)
            try opener(saved, args["app"].stringValue)
            return .object([
                "opened": .string(saved.path),
                "stageAttachment": .string(attachment.rawValue),
                "note": .string("snapshot opened — subsequent edits are not live in that window; call open_in_app again to refresh"),
            ])
        })
    }
}
