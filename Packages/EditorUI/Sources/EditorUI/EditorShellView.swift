import SwiftUI
import USDCore
import ViewportKit
import DicyaninDesignSystem

/// The editor shell: a top action bar, then outliner / viewport / inspector,
/// with a collapsible validation drawer under the viewport and modal surfaces
/// for conversion, batch, and scripts. Each panel is a thin view over an
/// already-tested engine (ConversionKit, ValidationKit, ScriptingKit).
/// (`ColorToken.color` now lives in Styling.swift, shared across panels.)
public struct EditorShellView: View {

    /// The live editing document (nil before a file is opened). Selection and
    /// all mutations flow through it so edits are undoable.
    let document: EditorDocument?
    @State private var searchText = ""
    @State private var collapsed: Set<PrimPath> = []

    /// Read-only stage view for the panels that only display state.
    private var stage: (any USDStageProtocol)? { document?.snapshot }
    /// Source file for the viewport's RealityKit fast path (Phase 1).
    private var modelURL: URL? { document?.modelURL }
    private var selection: Selection { document?.selection ?? .empty }

    private func select(_ path: PrimPath, additive: Bool = false) {
        document?.selection = selection.selecting(path, additive: additive)
    }

    @State private var showValidation = false
    @State private var activeSheet: Sheet?

    private enum Sheet: String, Identifiable {
        case convert, batch, scripts
        var id: String { rawValue }
    }

    /// Menu-bar commands post these; the shell mirrors its toolbar actions so
    /// menu shortcuts and toolbar buttons drive the same state.
    public enum MenuCommand: String {
        case convert, batch, scripts, validate
        public static let notification = Notification.Name("EditorUI.MenuCommand")
    }

    public init(document: EditorDocument? = nil) {
        self.document = document
    }

    public var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider().overlay(Palette.panelBorder.color)
            HSplitView {
                outliner
                    .frame(minWidth: 220, idealWidth: 260)
                centerColumn
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                InspectorView(document: document)
                    .frame(minWidth: 260, idealWidth: 300)
            }
        }
        .background(Palette.windowBackground.color)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .convert: ConversionSheet(onClose: dismissSheet)
            case .batch: BatchView(onClose: dismissSheet)
            case .scripts: ScriptsPanel(onClose: dismissSheet)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.notification)) { note in
            guard let raw = note.object as? String,
                  let command = MenuCommand(rawValue: raw) else { return }
            switch command {
            case .convert: activeSheet = .convert
            case .batch: activeSheet = .batch
            case .scripts: activeSheet = .scripts
            case .validate: if stage != nil { showValidation.toggle() }
            }
        }
    }

    private func dismissSheet() { activeSheet = nil }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: Spacing.sm) {
            actionButton("Convert", systemImage: "arrow.triangle.2.circlepath") { activeSheet = .convert }
            actionButton("Batch", systemImage: "square.stack.3d.up") { activeSheet = .batch }
            actionButton("Scripts", systemImage: "curlybraces") { activeSheet = .scripts }
            Divider().frame(height: 16).overlay(Palette.panelBorder.color)
            actionButton(showValidation ? "Hide Issues" : "Validate",
                         systemImage: "checkmark.shield",
                         isActive: showValidation) {
                showValidation.toggle()
            }
            Spacer()
            if let stage {
                Text("\(stage.primCount) prims")
                    .font(.system(size: TypeScale.caption, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Palette.panelBackground.color)
    }

    private func actionButton(_ title: String, systemImage: String,
                              isActive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: TypeScale.body, weight: .medium))
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Palette.accent.color.opacity(0.25) : .clear))
                .foregroundStyle(isActive ? Palette.accent.color : Palette.textPrimary.color)
        }
        .buttonStyle(.plain)
        // Conversion/batch/scripts work without an open stage; validation needs one.
        .disabled(stage == nil && title.hasPrefix("Validate"))
    }

    // MARK: Center column (viewport + validation drawer)

    private var centerColumn: some View {
        VSplitView {
            viewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showValidation {
                ValidationDrawer(
                    stage: stage,
                    onSelectPrim: { select($0) },
                    onClose: { showValidation = false })
                    .frame(minHeight: 140, idealHeight: 200, maxHeight: 320)
            }
        }
    }

    // MARK: Outliner

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
        .onTapGesture { select(row.path) }
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
}
