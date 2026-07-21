import SwiftUI
import MeshKit
import ViewportKit
import DicyaninDesignSystem

/// Built-in content library panel. Browses the parametric primitive shapes and
/// the low-poly prefab objects from `ShapeLibrary`, grouped by section and
/// category, and inserts the selected item into the open document as an
/// undoable command. The shape/prefab analog of `ScriptsPanel`.
struct LibraryPanel: View {
    let onClose: () -> Void
    /// The open document items are inserted into (nil before a file is opened).
    let document: EditorDocument?
    /// Creates a fresh, empty scratch document when none is open, so a primitive
    /// can be added to a brand-new scene. Returns nil if one can't be created.
    var onCreateDocument: () -> EditorDocument? = { nil }

    @State private var selectedID: String?
    @State private var status: String?
    /// Preview geometry built lazily per entry and cached, so re-selecting a
    /// shape never rebuilds its mesh (the heavy step is the half-edge build).
    @State private var previewCache: [String: ViewportMeshData] = [:]

    private var selectedEntry: ShapeEntry? {
        selectedID.flatMap(ShapeLibrary.entry(id:))
    }

    /// Preview mesh for the current selection, built on demand and memoised.
    private func previewMesh(for entry: ShapeEntry) -> ViewportMeshData? {
        if let cached = previewCache[entry.id] { return cached }
        guard let mesh = LibraryPreviewGeometry.viewportMesh(for: entry) else { return nil }
        previewCache[entry.id] = mesh
        return mesh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.panelBorder.color)
            HSplitView {
                list.frame(minWidth: 220, idealWidth: 260)
                detail.frame(minWidth: 220, maxWidth: .infinity)
            }
        }
        .frame(width: 620, height: 480)
        .background(Palette.windowBackground.color)
    }

    private var header: some View {
        HStack {
            Text("Library")
                .font(.system(size: TypeScale.title, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            Spacer()
            Button {
                insertSelected()
            } label: {
                Label("Add to Scene", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedEntry == nil)
            .accessibilityIdentifier("library.addSelected")
            Button("Close", action: onClose)
        }
        .padding(Spacing.sm)
    }

    private var list: some View {
        List(selection: $selectedID) {
            ForEach(LibraryGroup.allCases, id: \.self) { group in
                ForEach(ShapeLibrary.categories(in: group), id: \.self) { category in
                    Section("\(group.title) · \(category)") {
                        ForEach(ShapeLibrary.entries(in: group, category: category)) { entry in
                            row(entry).tag(entry.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ entry: ShapeEntry) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 18)
            Text(entry.name)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textPrimary.color)
        }
        .contentShape(Rectangle())
        // Double-click inserts, matching Finder-style "open".
        .onTapGesture(count: 2) { selectedID = entry.id; insertSelected() }
    }

    private var detail: some View {
        ZStack {
            Palette.viewportBackground.color
            if let entry = selectedEntry {
                // The 3D preview owns the pane; a single compact caption replaces
                // the old paragraphs of description.
                ShapePreviewView(mesh: previewMesh(for: entry), identity: entry.id)
                    .accessibilityIdentifier("library.preview")
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text(entry.name)
                        .font(.system(size: TypeScale.title, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary.color)
                    Text("\(entry.group.title) · \(entry.category)")
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                    if let status {
                        Text(status)
                            .font(.system(size: TypeScale.caption))
                            .foregroundStyle(Palette.textSecondary.color)
                    }
                }
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                Text("Select an item to preview it in 3D.")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func insertSelected() {
        guard let entry = selectedEntry else { return }
        status = Self.performInsert(entry, document: document,
                                    createDocument: onCreateDocument, dismiss: onClose)
    }

    /// Inserts `entry` into the open document (creating a scratch scene when
    /// none is open) and returns the status line to display. On success it also
    /// fires `dismiss`, closing the sheet so keyboard focus returns to the
    /// editor — otherwise the library sheet stays key and swallows the ⇥ the
    /// user presses next to enter edit mode on the object they just added.
    @MainActor
    static func performInsert(_ entry: ShapeEntry,
                              document: EditorDocument?,
                              createDocument: () -> EditorDocument?,
                              dismiss: () -> Void) -> String {
        // No file open yet? Start a fresh empty scene so the primitive has
        // somewhere to land, instead of silently doing nothing.
        guard let document = document ?? createDocument() else {
            return "Couldn’t create a scene to add \(entry.name) to."
        }
        if let error = LibraryInsertion.insert(entry, into: document) {
            return error
        }
        dismiss()
        return "Added \(entry.name) to the scene."
    }
}
