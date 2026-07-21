import SwiftUI
import AppKit
import UniformTypeIdentifiers
import USDCore
import ViewportKit
import ScriptingKit
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

    /// While a dropped/opened file is being imported through the USD bridge,
    /// the viewport shows a circular progress veil. Name is surfaced under it.
    let isImporting: Bool
    let importingFileName: String?

    /// The guided first-run tour, when running: drives a scripted camera and
    /// live transforms in the viewport, plus the narration card overlay.
    let tutorial: TutorialEngine?

    /// Builds the interpreter-backed executor for the Scripts panel (nil when
    /// no Python is available). Supplied by the app so a single located
    /// interpreter serves open/save/scripts.
    let makeScriptExecutor: () -> (any ScriptExecuting)?
    /// Re-imports a script-produced file into the scene (owned by the app,
    /// which holds the document).
    let onReimportFile: (URL) async -> Void

    /// Builds a fresh interactive-console controller wired to the live document
    /// (nil when no Python/document is available). Supplied by the app, which
    /// owns the bridge executor and StageSaver seams the console round-trips
    /// through. Rebuilt each time the console opens so it binds current state.
    let makeConsoleController: () -> ReplController?

    /// Creates a fresh, empty scratch document and makes it the live document,
    /// returning it. Lets features like the library start a new scene when none
    /// is open (nil if the host can't create one, e.g. previews).
    let onCreateDocument: () -> EditorDocument?

    /// Writes the live scene to `url`. Supplied by the app, which owns the USD
    /// bridge executor needed to package `.usdc`/`.usdz`. Defaults to a no-op so
    /// previews/tests can construct the shell without a bridge.
    let onExport: (URL) async throws -> Void

    /// File-menu operations that live in the app target (they drive AppKit
    /// panels / the document swap). Surfaced here so the command palette can list
    /// and invoke the same File actions the menu bar does — the "menu/shortcut/
    /// palette unification" the roadmap calls for. Default no-ops for previews.
    let onOpenFile: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void

    @State private var searchText = ""
    @State private var collapsed: Set<PrimPath> = []

    /// The row currently being renamed inline (nil when not editing), plus its
    /// working text. Committing runs an undoable `RenamePrimCommand`.
    @State private var renameTarget: PrimPath?
    @State private var renameText = ""

    /// The row a drag is currently hovering over (for a drop highlight).
    @State private var dropTarget: PrimPath?

    /// Read-only stage view for the panels that only display state.
    private var stage: (any USDStageProtocol)? { document?.snapshot }
    /// Source file for the viewport's RealityKit fast path (Phase 1).
    private var modelURL: URL? { document?.modelURL }
    private var selection: Selection { document?.selection ?? .empty }

    private func select(_ path: PrimPath, additive: Bool = false) {
        document?.selection = selection.selecting(path, additive: additive)
    }

    @State private var showValidation = false
    @State private var showMCPActivity = false
    /// Viewport image-based-lighting + background state (specs/viewport.md
    /// "Environment & Lighting"); edited via the popover control strip.
    @State private var environment = EnvironmentSettings()
    @State private var showEnvironment = false
    /// Drives the viewport animation transport (play/pause/scrub/loop). Kept in
    /// sync with the open stage's authored time range via `configure(from:)`.
    @State private var playback = PlaybackController()
    @State private var activeSheet: Sheet?
    /// The console controller for the currently-open console sheet (built via
    /// `makeConsoleController` when the console opens).
    @State private var consoleController: ReplController?

    /// ⌘K command palette: `showPalette` gates the overlay; `paletteModel` holds
    /// its query/results/selection. The action set is rebuilt against live
    /// context each time the palette opens (see `openCommandPalette`).
    @State private var showPalette = false
    @State private var paletteModel = CommandPaletteModel()

    /// Output format for the one-click export, shared with the export panel and
    /// persisted across launches.
    @AppStorage("editor.export.format") private var exportFormatRaw = ExportFormat.usdz.rawValue

    /// In-flight one-click export (drives the button spinner + disables re-fire).
    @State private var isExporting = false
    /// Outcome of the most recent export; drives the confirmation toast.
    @State private var exportResult: ExportResult?

    /// Result of an export attempt, surfaced as a transient toast.
    private struct ExportResult: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let errorMessage: String?
    }

    /// Live MCP agent activity (nil when the feature isn't wired, e.g. previews).
    /// Owned/updated by the app; observed inside the activity panel subviews.
    let mcpActivity: MCPActivityModel?


    private enum Sheet: String, Identifiable {
        case convert, batch, scripts, library, console, export
        var id: String { rawValue }
    }

    /// Menu-bar commands post these; the shell mirrors its toolbar actions so
    /// menu shortcuts and toolbar buttons drive the same state.
    public enum MenuCommand: String {
        case convert, batch, scripts, library, console, validate, mcpActivity, export, sculptDemo
        case commandPalette
        public static let notification = Notification.Name("EditorUI.MenuCommand")
    }

    public init(document: EditorDocument? = nil,
                isImporting: Bool = false,
                importingFileName: String? = nil,
                tutorial: TutorialEngine? = nil,
                mcpActivity: MCPActivityModel? = nil,
                makeScriptExecutor: @escaping () -> (any ScriptExecuting)? = { nil },
                onReimportFile: @escaping (URL) async -> Void = { _ in },
                makeConsoleController: @escaping () -> ReplController? = { nil },
                onCreateDocument: @escaping () -> EditorDocument? = { nil },
                onExport: @escaping (URL) async throws -> Void = { _ in },
                onOpenFile: @escaping () -> Void = {},
                onSave: @escaping () -> Void = {},
                onSaveAs: @escaping () -> Void = {}) {
        self.document = document
        self.isImporting = isImporting
        self.importingFileName = importingFileName
        self.tutorial = tutorial
        self.mcpActivity = mcpActivity
        self.makeScriptExecutor = makeScriptExecutor
        self.onReimportFile = onReimportFile
        self.makeConsoleController = makeConsoleController
        self.onCreateDocument = onCreateDocument
        self.onExport = onExport
        self.onOpenFile = onOpenFile
        self.onSave = onSave
        self.onSaveAs = onSaveAs
    }

    public var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider().overlay(Palette.panelBorder.color)
            HSplitView {
                outliner
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 320)
                centerColumn
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                InspectorView(document: document)
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 360)
            }
        }
        .background(Palette.windowBackground.color)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .convert: ConversionSheet(onClose: dismissSheet)
            case .batch: BatchView(onClose: dismissSheet)
            case .scripts:
                ScriptsPanel(onClose: dismissSheet,
                             inputURL: modelURL,
                             makeExecutor: makeScriptExecutor,
                             onReimport: onReimportFile)
            case .library:
                LibraryPanel(onClose: dismissSheet, document: document,
                             onCreateDocument: onCreateDocument)
            case .console:
                if let consoleController {
                    ConsolePanel(controller: consoleController, onClose: dismissSheet)
                } else {
                    unavailableSheet("The Python console needs an open document and a Python runtime.")
                }
            case .export:
                ExportPanel(sourceURL: modelURL,
                            // Re-evaluated per profile change against the live
                            // snapshot, so the gate reflects edits made while
                            // the sheet is open rather than a stale check.
                            evaluate: stage.map { current in
                                { ExportGate.evaluate(stage: current, profileID: $0) }
                            },
                            onExport: { runExport(to: $0) },
                            onClose: dismissSheet)
            }
        }
        .overlay(alignment: .bottom) { exportToast }
        .onReceive(NotificationCenter.default.publisher(for: MenuCommand.notification)) { note in
            guard let raw = note.object as? String,
                  let command = MenuCommand(rawValue: raw) else { return }
            switch command {
            case .convert: activeSheet = .convert
            case .batch: activeSheet = .batch
            case .scripts: activeSheet = .scripts
            case .library: activeSheet = .library
            case .console: openConsole()
            case .validate: if stage != nil { showValidation.toggle() }
            case .mcpActivity: if mcpActivity != nil { showMCPActivity.toggle() }
            case .export: if document != nil { activeSheet = .export }
            case .sculptDemo:
                if let document {
                    // Build the demo house live in the viewport, pass by pass.
                    Task { await SculptBuildRunner.playLive(SculptDemos.lowPolyHouse(), into: document) }
                }
            case .commandPalette: openCommandPalette()
            }
        }
        .overlay {
            if showPalette {
                CommandPaletteBackdrop(model: paletteModel, onClose: dismissPalette)
            }
        }
    }

    // MARK: Command palette

    /// Rebuilds the action set against the current document/context and opens the
    /// palette fresh (cleared query, first row highlighted).
    private func openCommandPalette() {
        paletteModel.setActions(paletteActions())
        paletteModel.reset()
        showPalette = true
    }

    private func dismissPalette() { showPalette = false }

    /// The unified action list backing the palette. Each entry mirrors an
    /// existing menu/toolbar command so a command has exactly one behaviour
    /// regardless of how it's invoked. `isEnabled` matches the menu's own
    /// enablement; disabled rows still appear (greyed) so the palette is a
    /// faithful mirror of what's available.
    private func paletteActions() -> [PaletteAction] {
        let hasDocument = document != nil
        let hasStage = stage != nil
        let canUndo = document?.canUndo ?? false
        let canRedo = document?.canRedo ?? false

        func action(_ id: String, _ title: String, _ category: String,
                    shortcut: String? = nil, keywords: [String] = [],
                    enabled: Bool = true, _ run: @escaping () -> Void) -> PaletteAction {
            PaletteAction(item: ActionItem(id: id, title: title, category: category,
                                           shortcut: shortcut, keywords: keywords,
                                           isEnabled: enabled),
                          run: run)
        }

        return [
            action("file.open", "Open…", "File", shortcut: "⌘O",
                   keywords: ["import", "load"]) { onOpenFile() },
            action("file.save", "Save", "File", shortcut: "⌘S",
                   enabled: hasDocument) { onSave() },
            action("file.saveAs", "Save As…", "File", shortcut: "⇧⌘S",
                   enabled: hasDocument) { onSaveAs() },
            action("file.export", "Export…", "File", shortcut: "⇧⌘E",
                   keywords: ["usdz", "share"], enabled: hasDocument) { activeSheet = .export },

            action("edit.undo", "Undo", "Edit", shortcut: "⌘Z",
                   enabled: canUndo) { document?.undo() },
            action("edit.redo", "Redo", "Edit", shortcut: "⇧⌘Z",
                   enabled: canRedo) { document?.redo() },

            action("convert.file", "Convert File…", "Convert", shortcut: "⇧⌘K",
                   keywords: ["glb", "gltf", "obj", "fbx"]) { activeSheet = .convert },
            action("convert.batch", "Batch Convert…", "Convert", shortcut: "⇧⌘B") { activeSheet = .batch },
            action("convert.library", "Library…", "Convert", shortcut: "⇧⌘L",
                   keywords: ["shapes", "primitives", "insert"]) { activeSheet = .library },
            action("convert.scripts", "Scripts…", "Convert",
                   keywords: ["python", "run"]) { activeSheet = .scripts },
            action("convert.console", "Python Console…", "Convert", shortcut: "⇧⌘P",
                   keywords: ["repl", "terminal"], enabled: hasDocument) { openConsole() },
            action("convert.sculpt", "Sculpt Demo House", "Convert", shortcut: "⇧⌘H",
                   enabled: hasDocument) {
                if let document {
                    Task { await SculptBuildRunner.playLive(SculptDemos.lowPolyHouse(), into: document) }
                }
            },

            action("view.validate", showValidation ? "Hide Issues" : "Validate Stage", "View",
                   shortcut: "⌘U", keywords: ["diagnostics", "check", "compliance"],
                   enabled: hasStage) { if stage != nil { showValidation.toggle() } },
            action("view.environment", showEnvironment ? "Hide Environment" : "Environment…", "View",
                   keywords: ["lighting", "ibl", "background", "hdr"]) { showEnvironment.toggle() },
            action("view.agent", "Show Agent Activity", "View", shortcut: "⇧⌘M",
                   keywords: ["mcp"], enabled: mcpActivity != nil) {
                if mcpActivity != nil { showMCPActivity.toggle() }
            },
        ]
    }

    private func dismissSheet() { activeSheet = nil }

    /// Builds a fresh console controller bound to current state, then opens the
    /// console sheet. No-op when the host can't supply one (no document/Python).
    private func openConsole() {
        guard let controller = makeConsoleController() else { return }
        consoleController = controller
        activeSheet = .console
    }

    /// Placeholder shown when a sheet's backing feature isn't available.
    private func unavailableSheet(_ message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: TypeScale.title))
                .foregroundStyle(Palette.textSecondary.color)
            Text(message)
                .font(.system(size: TypeScale.body))
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.center)
            Button("Close", action: dismissSheet).keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.xl)
        .frame(width: 420, height: 240)
        .background(Palette.windowBackground.color)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: Spacing.xs) {
            actionButton("Convert", systemImage: "arrow.triangle.2.circlepath") { activeSheet = .convert }
            actionButton("Batch", systemImage: "square.stack.3d.up") { activeSheet = .batch }
            actionButton("Scripts", systemImage: "curlybraces") { activeSheet = .scripts }
            actionButton("Console", systemImage: "terminal") { openConsole() }
                .disabled(document == nil)
            Divider().frame(height: 16).overlay(Palette.borderSubtle.color)
            actionButton(showValidation ? "Hide Issues" : "Validate",
                         systemImage: "checkmark.shield",
                         isActive: showValidation) {
                showValidation.toggle()
            }
            Divider().frame(height: 16).overlay(Palette.borderSubtle.color)
            actionButton("Library", systemImage: "square.grid.2x2") { activeSheet = .library }
            Spacer()
            if let mcpActivity {
                MCPStatusAccessory(model: mcpActivity, showActivity: $showMCPActivity)
            }
            if let stage {
                StatusPill(text: "\(stage.primCount) prims", tint: Palette.success)
            }
            ExportButton(onQuickExport: quickExport,
                         onOpenPanel: { activeSheet = .export },
                         isEnabled: document != nil,
                         isBusy: isExporting)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        // The bar is a fixed-height chrome strip: controls inside it may not
        // dictate its height (a tall control like ExportButton would otherwise
        // stretch the whole row). Anything taller is clipped, not accommodated.
        .frame(height: Self.actionBarHeight)
        .background(Palette.surfaceElevated.color)
    }

    /// Fixed height of the top action bar, in points.
    static let actionBarHeight: CGFloat = 44

    // MARK: Export

    private var exportFormat: ExportFormat {
        ExportFormat(rawValue: exportFormatRaw) ?? .usdz
    }

    /// One-click export: writes the live scene to the smart destination (beside
    /// the open file, or the Desktop when untitled) with no dialog.
    private func quickExport() {
        guard document != nil else { return }
        let fallback = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let destination = ExportPlan.smartDestination(
            sourceURL: modelURL, format: exportFormat, fallbackDirectory: fallback)
        runExport(to: destination)
    }

    /// Performs the write through the app-supplied `onExport`, then raises a
    /// success/failure toast.
    private func runExport(to destination: URL) {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            do {
                try await onExport(destination)
                exportResult = ExportResult(url: destination, errorMessage: nil)
            } catch {
                exportResult = ExportResult(url: destination, errorMessage: "\(error)")
            }
        }
    }

    @ViewBuilder
    private var exportToast: some View {
        if let result = exportResult {
            ExportToast(fileName: result.url.lastPathComponent,
                        errorMessage: result.errorMessage,
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([result.url]) },
                        onDismiss: { exportResult = nil })
                .padding(.bottom, Spacing.lg)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: result.id) {
                    // Auto-dismiss the success toast after a few seconds; errors
                    // stay until dismissed so they aren't missed.
                    guard result.errorMessage == nil else { return }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if exportResult?.id == result.id { exportResult = nil }
                }
        }
    }

    private func actionButton(_ title: String, systemImage: String,
                              isActive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(ToolbarButtonStyle(isActive: isActive))
        // Conversion/batch/scripts work without an open stage; validation needs one.
        .disabled(stage == nil && title.hasPrefix("Validate"))
    }

    // MARK: Center column (viewport + validation drawer)

    private var centerColumn: some View {
        VSplitView {
            viewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isImporting {
                        ImportProgressOverlay(fileName: importingFileName)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isImporting)
            if showValidation {
                ValidationDrawer(
                    stage: stage,
                    onSelectPrim: { select($0) },
                    quickFix: { document?.quickFix(for: $0) },
                    onApplyFix: { document?.applyQuickFix(for: $0) },
                    onClose: { showValidation = false })
                    .frame(minHeight: 140, idealHeight: 200, maxHeight: 320)
            }
            if showMCPActivity, let mcpActivity {
                MCPActivityPanel(model: mcpActivity, onClose: { showMCPActivity = false })
                    .frame(minHeight: 140, idealHeight: 220, maxHeight: 360)
            }
        }
    }

    // MARK: Outliner

    private var outliner: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Outliner", systemImage: "list.bullet.indent")
            FilterField(placeholder: "Filter prims", text: $searchText)
                .padding(Spacing.xs)
            List(filteredRows) { row in
                outlinerRow(row)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Palette.panelBackground.color)
        // Dropping onto empty outliner space reparents to the stage root.
        .dropDestination(for: String.self) { items, _ in
            reparentDropped(items, under: nil)
        }
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

            if renameTarget == row.path {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: TypeScale.body))
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
            } else {
                Text(row.path.name)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(row.isActive
                        ? Palette.textPrimary.color
                        : Palette.textSecondary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.visibility == .invisible {
                Image(systemName: "eye.slash")
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(rowBackground(row, isSelected: isSelected))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(isSelected ? Palette.accent.color.opacity(0.35) : .clear,
                              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // ⇧-click extends the multi-selection; a plain click replaces it.
            select(row.path, additive: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu { rowContextMenu(row) }
        // Drag a prim onto another to reparent it (world-transform preserving).
        .draggable(row.path.description)
        .dropDestination(for: String.self) { items, _ in
            reparentDropped(items, under: row.path)
        } isTargeted: { hovering in
            dropTarget = hovering ? row.path : (dropTarget == row.path ? nil : dropTarget)
        }
    }

    /// Selection tint, or a stronger accent while a valid drag hovers the row.
    private func rowBackground(_ row: OutlinerModel.Row, isSelected: Bool) -> Color {
        if dropTarget == row.path { return Palette.accent.color.opacity(0.35) }
        return isSelected ? Palette.accent.color.opacity(0.16) : .clear
    }

    // MARK: Outliner context menu

    @ViewBuilder
    private func rowContextMenu(_ row: OutlinerModel.Row) -> some View {
        Button("Rename") { beginRename(row.path) }
        Button("Duplicate") { document?.duplicate(row.path) }

        if selection.paths.count >= 2 {
            Button("Group Selection") { document?.groupSelection() }
        }
        if row.path.depth > 1 {
            Button("Move to Root") { document?.reparent(row.path, under: nil) }
        }

        Divider()

        Button(document?.isolation.isActive == true ? "Exit Isolate" : "Isolate Selection") {
            if document?.isolation.isActive == true { document?.exitIsolation() }
            else { select(row.path); document?.isolateSelection() }
        }
        .help("Focus the viewport on this part only. View-only — nothing is written to the file.")

        Divider()

        // Hide vs. Disable vs. Delete, presented together with explicit copy —
        // this distinction is the top user-confusion risk (specs/editor-ui.md),
        // so each control spells out exactly what it does.
        ForEach(document?.partEditControls(for: row.path) ?? []) { control in
            Button(control.title, role: control.isDestructive ? .destructive : nil) {
                document?.performPartEdit(control.kind, on: row.path)
            }
            .help(control.help)
        }
    }

    // MARK: Inline rename

    private func beginRename(_ path: PrimPath) {
        renameText = path.name
        renameTarget = path
    }

    private func commitRename() {
        if let path = renameTarget { document?.rename(path, to: renameText) }
        cancelRename()
    }

    private func cancelRename() {
        renameTarget = nil
        renameText = ""
    }

    // MARK: Drag-and-drop reparenting

    /// Reparents each dragged path (encoded as its string description) under
    /// `newParent` (root when `nil`). Returns whether anything moved.
    private func reparentDropped(_ items: [String], under newParent: PrimPath?) -> Bool {
        guard let document else { return false }
        var moved = false
        for item in items {
            guard let path = PrimPath(item) else { continue }
            document.reparent(path, under: newParent)
            moved = true
        }
        dropTarget = nil
        return moved
    }

    /// Tab toggles object ⇄ edit mode against the current selection
    /// (specs/mesh-editing.md §Component mode).
    private var editModeToggleShortcut: some View {
        Button("") { document?.toggleMeshEditMode() }
            .keyboardShortcut(.tab, modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
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

    /// Top-trailing button that opens the environment/lighting popover.
    private var environmentButton: some View {
        Button {
            showEnvironment.toggle()
        } label: {
            Image(systemName: "sun.max")
        }
        .buttonStyle(.borderless)
        .help("Environment & lighting")
        .padding(8)
        .popover(isPresented: $showEnvironment, arrowEdge: .top) {
            EnvironmentControls(settings: $environment,
                                onChooseCustomEnvironment: Self.chooseEnvironmentFile)
                .frame(width: 280)
        }
    }

    /// Presents an open panel for a custom `.hdr`/`.exr` environment map.
    static func chooseEnvironmentFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = EnvironmentModel.supportedFileExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @ViewBuilder
    private var viewport: some View {
        // Always render the live viewport — with no document open it shows the
        // default empty scene (grid + axis gizmo wireframe) rather than an
        // "open a file" placeholder, so the app opens straight into 3D space.
        ViewportPane(
                modelURL: modelURL,
                livePrimPaths: document?.viewportLivePrimPaths,
                sceneRevision: document?.viewportSceneRevision ?? 0,
                scene: document?.viewportScene,
                editedMesh: document?.viewportEditedMesh,
                onPickFace: { [weak document] index, additive in
                    document?.pickMeshFace(index: index, additive: additive)
                },
                // Blender-style Tab: toggle edit mode when the viewport has
                // focus. Reliable here (the viewport view catches the keyDown);
                // the hidden `editModeToggleShortcut` button is the fallback for
                // when focus sits in another pane.
                onToggleEditMode: { [weak document] in document?.toggleMeshEditMode() },
                hoverPreview: document?.meshEdit?.hoverPreviewEnabled ?? false,
                onHoverFace: { [weak document] index in document?.hoverMeshFace(index: index) },
                extrudeGizmo: document?.meshEditExtrudeGizmo,
                onGizmoDrag: { [weak document] phase in
                    document?.handleExtrudeGizmoDrag(phase)
                },
                translateGizmo: document?.translateGizmo,
                onTranslateGizmoDrag: { [weak document] phase in
                    document?.handleTranslateGizmoDrag(phase)
                },
                rotateGizmo: document?.rotateGizmo,
                onRotateGizmoDrag: { [weak document] phase in
                    document?.handleRotateGizmoDrag(phase)
                },
                scaleGizmo: document?.scaleGizmo,
                onScaleGizmoDrag: { [weak document] phase in
                    document?.handleScaleGizmoDrag(phase)
                },
                cameraPose: tutorial?.cameraPose,
                // The tour's scripted tweens own the channel while running;
                // otherwise the document's authored transforms render live
                // (gizmo drags, inspector edits, undo).
                liveTransforms: tutorial?.liveTransforms ?? document?.viewportLiveTransforms,
                materialOverrides: document?.viewportMaterialOverrides,
                environment: environment,
                animationTime: playback.animationTime)
                .overlay(alignment: .topTrailing) { environmentButton }
                .onAppear { playback.configure(from: stage?.metadata) }
                .onChange(of: stage?.metadata) { _, newValue in
                    playback.configure(from: newValue)
                }
                .overlay {
                    // Mesh edit mode: tool strip + active-tool indicator over
                    // the viewport (Phase 6; specs/mesh-editing.md).
                    if let document { MeshEditOverlay(document: document) }
                }
                .overlay(alignment: .top) {
                    // Drill-down breadcrumb + isolate indicator (Milestone 3).
                    if let document { BreadcrumbBar(document: document) }
                }
                .overlay(alignment: .bottom) {
                    // The tour's narration card owns the bottom edge while it
                    // runs; the hotkey hints return afterwards. The transport bar
                    // (auto-hidden without animation) sits above whichever shows.
                    VStack(spacing: 0) {
                        if let tutorial {
                            TutorialOverlay(engine: tutorial)
                        } else if let document {
                            ViewportHintOverlay(document: document)
                        }
                        if playback.isAvailable {
                            PlaybackTransportBar(controller: playback)
                        }
                    }
                }
                .background(editModeToggleShortcut)
                .background(partEditingShortcuts)
    }

    /// Hidden hotkeys for part-level navigation (ROADMAP Milestone 3):
    /// ⌘↑ walk-up, ⌘I toggle isolate, Esc exit isolate.
    @ViewBuilder
    private var partEditingShortcuts: some View {
        if let document {
            Group {
                Button("") { document.walkUpSelection() }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("") { document.toggleIsolation() }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("") { document.exitIsolation() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }
}
