import SwiftUI
import MeshKit
import DicyaninDesignSystem

/// Built-in content library panel. Browses the parametric primitive shapes and
/// the low-poly prefab objects from `ShapeLibrary`, grouped by section and
/// category, and inserts the selected item into the open document as an
/// undoable command. The shape/prefab analog of `ScriptsPanel`.
struct LibraryPanel: View {
    let onClose: () -> Void
    /// The open document items are inserted into (nil before a file is opened).
    let document: EditorDocument?

    @State private var selectedID: String?
    @State private var status: String?

    private var selectedEntry: ShapeEntry? {
        selectedID.flatMap(ShapeLibrary.entry(id:))
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
            .disabled(selectedEntry == nil || document == nil)
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
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let entry = selectedEntry {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: entry.systemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.accent.color)
                    VStack(alignment: .leading) {
                        Text(entry.name)
                            .font(.system(size: TypeScale.title, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary.color)
                        Text("\(entry.group.title) · \(entry.category)")
                            .font(.system(size: TypeScale.caption))
                            .foregroundStyle(Palette.textSecondary.color)
                    }
                }
                Text(entry.group == .primitives
                     ? "A parametric primitive shape, inserted at the world origin."
                     : "A low-poly object composed from primitives, resting on the ground plane.")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
                if let status {
                    Text(status)
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(Palette.textSecondary.color)
                }
                Spacer()
            } else {
                Spacer()
                Text("Select an item to insert into your scene.")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(Palette.viewportBackground.color)
    }

    private func insertSelected() {
        guard let entry = selectedEntry, let document else { return }
        if let error = LibraryInsertion.insert(entry, into: document) {
            status = error
        } else {
            status = "Added \(entry.name) to the scene."
        }
    }
}
