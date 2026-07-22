import Foundation

/// Reference-image tools (§ specs/agent-live-editing.md — "Reference panel").
/// Let an agent that is reconstructing a model from a reference push that image
/// into the editor's reference panel (above the inspector). The image is passed
/// by absolute path — the same convention the sculpt tools use for
/// `referencePath` — so the running editor shows it live, and an image set
/// before the window opens is picked up when the app is launched by the agent
/// or the CLI.
public enum ReferenceImageTools {

    public static func register(on server: MCPServer, session: EditSession) {
        server.register(MCPTool(
            name: "set_reference_image", group: .asset,
            description: """
                Show a reference image in the editor's reference panel (above the \
                inspector). Pass an absolute file path to a PNG/JPEG the agent is \
                working from; an optional caption labels it. A running editor \
                updates live; a path set before the window opens is shown when the \
                app launches.
                """,
            inputSchema: Schema.object([
                "path": Schema.string("absolute path to the reference image (PNG/JPEG)"),
                "caption": Schema.string("optional short label shown under the image"),
            ], required: ["path"])
        ) { args in
            guard let raw = args["path"].stringValue, !raw.isEmpty else {
                throw ToolError.invalidParams("missing 'path' (absolute path to an image file)")
            }
            let url = URL(fileURLWithPath: raw)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError.failed("no file at '\(raw)'")
            }
            // Treat an empty caption as absent so the panel doesn't render a blank pill.
            let caption = args["caption"].stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let image = ReferenceImage(path: url.path, caption: caption)
            session.setReferenceImage(image)
            return .object(["referenceImage": image.asJSON])
        })

        server.register(MCPTool(
            name: "clear_reference_image", group: .asset,
            description: "Remove the reference image from the editor's reference panel.",
            inputSchema: Schema.object([:])
        ) { _ in
            session.setReferenceImage(nil)
            return .object(["cleared": .bool(true)])
        })
    }
}
