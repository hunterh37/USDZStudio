import SwiftUI
import USDCore
import ViewportKit
import DicyaninDesignSystem

extension ColorToken {
    /// Maps a design-system token to SwiftUI.
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Phase 0 chrome: left outliner / center viewport placeholder / right
/// inspector placeholder (specs/editor-ui.md). Panels become real in Phase 1.
public struct EditorShellView: View {

    let stage: (any USDStageProtocol)?
    /// Source file for the viewport's RealityKit fast path (Phase 1).
    let modelURL: URL?
    @State private var selection = Selection.empty
    @State private var searchText = ""
    @State private var collapsed: Set<PrimPath> = []

    public init(stage: (any USDStageProtocol)? = nil, modelURL: URL? = nil) {
        self.stage = stage
        self.modelURL = modelURL
    }

    public var body: some View {
        HSplitView {
            outliner
                .frame(minWidth: 220, idealWidth: 260)
            viewport
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            inspectorPlaceholder
                .frame(minWidth: 240, idealWidth: 280)
        }
        .background(Palette.windowBackground.color)
    }

    private var outliner: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField("Filter", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(Spacing.xs)
            List(filteredRows) { row in
                outlinerRow(row)
            }
            .listStyle(.sidebar)
        }
        .background(Palette.panelBackground.color)
    }

    /// A single outliner row: disclosure chevron (for rows with children),
    /// name, and a visibility indicator. The whole row is tappable to select,
    /// and highlights when it's part of the current selection.
    @ViewBuilder
    private func outlinerRow(_ row: OutlinerModel.Row) -> some View {
        let isSelected = selection.contains(row.path)
        HStack(spacing: Spacing.xxs) {
            // Indentation grows with depth so nested levels read as a tree.
            Color.clear
                .frame(width: Double(row.depth) * Spacing.md, height: 1)

            // Disclosure triangle only where there's a subtree to fold.
            if row.hasChildren {
                Button {
                    toggleCollapsed(row.path)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: TypeScale.caption, weight: .semibold))
                        .rotationEffect(.degrees(collapsed.contains(row.path) ? 0 : 90))
                        .foregroundStyle(Palette.textSecondary.color)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }

            Text(row.path.name)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(row.isActive
                    ? Palette.textPrimary.color
                    : Palette.textSecondary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            if row.visibility == .invisible {
                Image(systemName: "eye.slash")
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Palette.accent.color.opacity(0.25) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = selection.selecting(row.path) }
    }

    private func toggleCollapsed(_ path: PrimPath) {
        if collapsed.contains(path) {
            collapsed.remove(path)
        } else {
            collapsed.insert(path)
        }
    }

    private var filteredRows: [OutlinerModel.Row] {
        guard let stage else { return [] }
        // While filtering, show the full matching tree (ignore collapse) so
        // matches are never hidden inside a folded parent.
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let rows = query.isEmpty
            ? OutlinerModel.rows(for: stage, collapsed: collapsed)
            : OutlinerModel.rows(for: stage)
        return OutlinerModel.filtered(rows, searchText: searchText)
    }

    @ViewBuilder
    private var viewport: some View {
        if let modelURL {
            ViewportPane(modelURL: modelURL)
        } else {
            ZStack {
                Palette.viewportBackground.color
                Text("Open a USDZ to begin")
                    .font(.system(size: TypeScale.title))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
    }

    private var inspectorPlaceholder: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Inspector")
                .font(.system(size: TypeScale.heading, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            if let path = selection.primary {
                Text(path.description)
                    .font(.system(size: TypeScale.body, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary.color)
            } else {
                Text("No selection")
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
            }
            Spacer()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panelBackground.color)
    }
}
