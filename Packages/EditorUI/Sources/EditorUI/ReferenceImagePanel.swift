import SwiftUI
import AppKit
import DicyaninDesignSystem

/// Presentational state for the reference-image panel above the inspector. The
/// app owns an instance and updates it — from the in-app MCP host as the agent
/// calls `set_reference_image`, or from the on-launch hand-off file when the
/// editor is started by the agent/CLI after the image was set. The panel
/// observes it.
///
/// Lives in EditorUI (which dependency-lint forbids from importing AgentMCP), so
/// it carries only plain values — a path and caption — not the AgentMCP type.
/// The app translates the AgentMCP `ReferenceImage` into these fields
/// (specs/agent-live-editing.md — "Reference panel").
@MainActor
public final class ReferenceImageModel: ObservableObject {
    /// Absolute path to the reference image on disk (nil when none set).
    @Published public var path: String?
    /// Optional short caption shown under the image.
    @Published public var caption: String?

    public init(path: String? = nil, caption: String? = nil) {
        self.path = path
        self.caption = caption
    }

    /// A reference image is currently set (drives the panel's visibility).
    public var hasReference: Bool { path != nil }

    /// Set (or clear, with a nil path) the reference image.
    public func set(path: String?, caption: String?) {
        self.path = path
        self.caption = caption
    }
}

/// The reference-image panel shown above the inspector while the agent is
/// working from a reference. Loads the image straight off disk (the path the
/// MCP tool supplied) and renders it aspect-fit over the sunken surface, with an
/// explicit "missing file" state when the path no longer resolves.
struct ReferenceImagePanel: View {
    @ObservedObject var model: ReferenceImageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Reference", systemImage: "photo") {
                if let caption = model.caption, !caption.isEmpty {
                    StatusPill(text: caption)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surfaceSunken.color)
        }
        .background(Palette.panelBackground.color)
    }

    @ViewBuilder
    private var content: some View {
        if let path = model.path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.sm)
                .accessibilityLabel(model.caption ?? "Reference image")
        } else if model.path != nil {
            // Set but unreadable — the file was moved or deleted after it was set.
            message(icon: "exclamationmark.triangle", text: "Reference image not found")
        } else {
            message(icon: "photo", text: "No reference image")
        }
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Palette.textTertiary.color)
            Text(text)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Palette.textTertiary.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.sm)
    }
}

/// The editor's right column: the reference-image panel (only while a reference
/// is set) stacked above the inspector. A dedicated view so it observes the
/// model and the panel appears/disappears reactively as the agent sets or
/// clears the reference.
struct InspectorColumn: View {
    let document: EditorDocument?
    @ObservedObject var referenceImage: ReferenceImageModel

    var body: some View {
        VStack(spacing: 0) {
            if referenceImage.hasReference {
                ReferenceImagePanel(model: referenceImage)
                    .frame(minHeight: 140, idealHeight: 200, maxHeight: 280)
                Divider().overlay(Palette.panelBorder.color)
            }
            InspectorView(document: document)
        }
    }
}
