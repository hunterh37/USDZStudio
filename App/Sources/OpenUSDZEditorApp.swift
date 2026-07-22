import SwiftUI
import EditorUI
import USDBridge
import USDCore
import ScriptingKit
import SessionKit

/// Thin app target: SwiftUI lifecycle + DI wiring only (<200 lines by design,
/// specs/testing.md). The real document-based architecture arrives with the
/// Phase 1 viewer; Phase 0 exit criterion is: open a USDZ, see its prim tree.
/// When launched via `swift run` (no .app bundle), macOS treats the executable
/// as a background accessory: the window never comes forward. Promoting the
/// activation policy to `.regular` and activating makes the dev-run behave like
/// the eventual bundled app. No-op cost for the packaged build.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove the discovery file + UNIX socket so a later-spawned pump doesn't
        // try to reach a dead editor — but only if this instance owns them, so a
        // quitting second instance never orphans the first's endpoint.
        MCPActivityListener.removeEndpointIfOwned()
    }
}

@main
struct OpenUSDZEditorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var document: EditorDocument?
    @State private var openError: String?

    /// Drives cross-launch session restore (specs/session-restoration.md): owns
    /// the per-document write-ahead-log session and the view-state envelope, so a
    /// relaunch can rebuild the scene, its unsaved edits, and the undo/redo stack.
    @State private var session = SessionController()

    /// Set on launch when a previous session with unsaved work is found; drives
    /// the "restore your previous session?" prompt. The document is rebuilt
    /// up-front (recovery is cheap) so accepting is instant.
    @State private var restoreCandidate: SessionController.Recoverable?
    @State private var restoredDocument: EditorDocument?
    @State private var showRestorePrompt = false

    /// Drives the File ▸ "Reset Session" confirmation.
    @State private var showResetSessionPrompt = false

    /// The shell-owned view state to reapply after accepting a restore (camera,
    /// outliner expansion, panels, playback); `nil` for a normal open, so a
    /// later open never re-applies a stale restore.
    @State private var restoredViewStateToApply: ViewState?

    /// App-wide persisted preferences, shared by the editor shell and the
    /// Settings (⌘,) window.
    @State private var settings = EditorSettings()

    /// True while an opened/dropped file is importing through the USD bridge;
    /// drives the viewport's circular progress overlay.
    @State private var isImporting = false
    @State private var importingFileName: String?

    /// The guided first-run tour. Auto-launches once (per `hasSeenTutorial`)
    /// when the app opens with no document; replayable any time via
    /// Help ▸ Welcome Tour (⌘?).
    @State private var tutorial: TutorialEngine?
    @State private var documentBeforeTutorial: EditorDocument?
    @AppStorage("editor.hasSeenTutorial") private var hasSeenTutorial = false

    /// Hosts the localhost activity listener and the model the MCP panel + tray
    /// observe. Started once at launch.
    @StateObject private var mcp = MCPActivityListener()

    var body: some Scene {
        WindowGroup("Open USDZ Editor") {
            EditorShellView(document: document,
                            isImporting: isImporting,
                            importingFileName: importingFileName,
                            tutorial: tutorial,
                            mcpActivity: mcp.model,
                            referenceImage: mcp.referenceModel,
                            settings: settings,
                            makeScriptExecutor: {
                                ProcessScriptExecutor(
                                    bridge: ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath))
                            },
                            onReimportFile: { url in await reimport(url) },
                            makeConsoleController: { makeConsoleController() },
                            onCreateDocument: {
                                // Start a fresh, empty scratch scene (no backing
                                // file) so the library can add primitives without
                                // opening a file first. A journaled session is
                                // started so its edits survive a relaunch.
                                restoredViewStateToApply = nil
                                let journal = session.begin(for: nil)
                                let doc = EditorDocument(journal: journal)
                                session.attach(doc)
                                session.capture(doc)
                                document = doc
                                return doc
                            },
                            onExport: { url in try await export(to: url) },
                            onOpenFile: { presentOpenPanel() },
                            onSave: { save(to: document?.modelURL) },
                            onSaveAs: { save(to: nil) },
                            session: session,
                            restoredViewState: restoredViewStateToApply)
                .frame(minWidth: 1000, minHeight: 620)
                .alert("Could Not Open File", isPresented: .constant(openError != nil)) {
                    Button("OK") { openError = nil }
                } message: {
                    Text(openError ?? "")
                }
                .onOpenURL(perform: open)
                // Scene-phase capture (including shell-owned camera/panels/
                // outliner state) is owned by EditorShellView, which holds that
                // @State; the App only kicks off the initial envelope on open.
                // Restore-but-prompt: the document is already rebuilt, so this is
                // a pure yes/no (specs/session-restoration.md).
                .confirmationDialog("Restore your previous session?",
                                    isPresented: $showRestorePrompt, titleVisibility: .visible) {
                    Button("Restore") {
                        // Hand the shell-owned view state to EditorShellView to
                        // reapply (camera, outliner, panels); document-owned
                        // state was already applied by SessionController.restore.
                        restoredViewStateToApply = restoreCandidate?.document.viewState
                        if let restoredDocument { document = restoredDocument }
                        restoreCandidate = nil
                        restoredDocument = nil
                    }
                    Button("Start Fresh", role: .destructive) {
                        if let restoreCandidate { session.discard(restoreCandidate) }
                        session.endActive()
                        restoreCandidate = nil
                        restoredDocument = nil
                    }
                } message: {
                    Text(restorePromptMessage)
                }
                .confirmationDialog("Reset session?",
                                    isPresented: $showResetSessionPrompt, titleVisibility: .visible) {
                    Button("Reset Session", role: .destructive) { resetSession() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears saved session-restoration data — the current session and any recoverable sessions from previous launches. The app won't offer to restore them next time it opens. Any document you have open stays open; its saved file is untouched.")
                }
                .task {
                    // Start the localhost activity listener + write the
                    // endpoint-discovery file so `openusdz mcp` can connect.
                    mcp.start()
                    // Offer to restore a previous session with unsaved work
                    // before anything else opens a document.
                    if document == nil { await offerSessionRestore() }
                    // Dev convenience: `swift run OpenUSDZEditorApp file.usda`
                    // opens straight into the file.
                    if document == nil, !showRestorePrompt,
                       let arg = CommandLine.arguments.dropFirst().first(where: {
                           ["usda", "usdz", "usdc", "usd"].contains(URL(fileURLWithPath: $0).pathExtension)
                       }) {
                        open(URL(fileURLWithPath: arg))
                    }
                    // First run, nothing open (and not awaiting a restore
                    // decision): show the guided tour.
                    if document == nil && !showRestorePrompt && !hasSeenTutorial {
                        startTutorial()
                    }
                    // Host the agent editing session on the current document so
                    // agent MCP edits render live in this window (specs/agent-live-editing.md).
                    mcp.bindDocument(document)
                }
                .onChange(of: document.map(ObjectIdentifier.init)) {
                    mcp.bindDocument(document)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in open(url) } }
                    }
                    return true
                }
        }
        // Size the window from the content's *minimum*, not its ideal, size.
        // Guards against any panel's content-driven ideal height (e.g. the
        // outliner List growing per row) pushing the window root larger.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { save(to: document?.modelURL) }
                    .keyboardShortcut("s")
                    .disabled(document == nil)
                Button("Save As…") { save(to: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(document == nil)
                Divider()
                Button("Export…") { postMenu(.export) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(document == nil)
                Divider()
                // Clears cross-launch session-restoration state
                // (specs/session-restoration.md): drops the active WAL plus any
                // recoverable leftovers so the next launch won't offer a
                // restore. Confirmed first — it discards unsaved recovery data.
                Button("Reset Session…") { showResetSessionPrompt = true }
            }
            // Drive undo/redo straight through the document's CommandStack. The
            // package's UndoManagerBridge stays available for the eventual
            // NSDocument architecture; here a single explicit path keeps ⌘Z
            // deterministic in the windowed dev app.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { document?.undo() }
                    .keyboardShortcut("z")
                    .disabled(document == nil)
                Button("Redo") { document?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(document == nil)
            }
            CommandMenu("Convert") {
                Button("Library…") { postMenu(.library) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Recolor…") { postMenu(.recolor) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(document == nil)
                Divider()
                Button("Convert File…") { postMenu(.convert) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Batch Convert…") { postMenu(.batch) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Validate Stage") { postMenu(.validate) }
                    .keyboardShortcut("u")
                    .disabled(document == nil)
                Button("Show Changes…") { postMenu(.diff) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(document == nil)
                Divider()
                Button("Sculpt Demo House") { postMenu(.sculptDemo) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(document == nil)
                Button("Scripts…") { postMenu(.scripts) }
                Button("Python Console…") { postMenu(.console) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(document == nil)
            }
            // Replace (not just prepend to) the default Help group. macOS
            // otherwise leaves its stock "OpenUSDZEditor Help" item in place,
            // which — with no bundled help book — pops the useless "Help isn't
            // available" alert. Here the Help menu re-runs the first-launch
            // guided tour instead.
            CommandGroup(replacing: .help) {
                Button("Welcome Tour") { startTutorial() }
                    .keyboardShortcut("/", modifiers: [.command, .shift]) // ⌘?
                    .disabled(tutorial != nil)
            }
            CommandGroup(after: .toolbar) {
                // ⌘K opens the command palette — the single entry point that
                // unifies menu/shortcut/palette (ROADMAP Phase 5 / Continuous).
                Button("Command Palette…") { postMenu(.commandPalette) }
                    .keyboardShortcut("k")
                Button("Show Agent Activity") {
                    postMenu(.mcpActivity)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MCPMenuBarContent(model: mcp.model, documentPath: document?.modelURL?.path)
        } label: {
            MCPMenuBarLabel(model: mcp.model)
        }
        .menuBarExtraStyle(.window)

        // Standard macOS Settings (⌘,) window over the shared preferences model.
        Settings {
            SettingsView(settings: settings)
        }
    }

    /// Swaps in the tour's sandbox document; the user's document (if any)
    /// returns untouched when the tour ends.
    private func startTutorial() {
        guard tutorial == nil, let engine = try? TutorialEngine() else { return }
        documentBeforeTutorial = document
        document = engine.document
        engine.onFinished = {
            document = documentBeforeTutorial
            documentBeforeTutorial = nil
            tutorial = nil
            hasSeenTutorial = true
        }
        tutorial = engine
        engine.start()
    }

    private func postMenu(_ command: EditorShellView.MenuCommand) {
        NotificationCenter.default.post(
            name: EditorShellView.MenuCommand.notification, object: command.rawValue)
    }

    /// Save (to the opened file) / Save As (panel when `url` is nil).
    private func save(to url: URL?) {
        guard let document else { return }
        let target: URL
        if let url {
            target = url
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "usdz"),
                                         .init(filenameExtension: "usda"),
                                         .init(filenameExtension: "usdc")].compactMap { $0 }
            panel.nameFieldStringValue = document.modelURL?.lastPathComponent ?? "Untitled.usdz"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            target = chosen
        }
        Task { @MainActor in
            do {
                let executor = ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath)
                try await document.save(to: target, executor: executor)
            } catch {
                openError = "Could not save \(target.lastPathComponent):\n\(error)"
            }
        }
    }

    /// Writes the live scene to `url` for the export flow (one-click button /
    /// export panel). Unlike Save, it never opens a dialog — the destination is
    /// already resolved by the shell — and it throws so the shell can toast the
    /// outcome. `.usdc`/`.usdz` targets go through the bundled bridge executor.
    @MainActor
    private func export(to url: URL) async throws {
        guard let document else { return }
        let executor = ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath)
        try await document.save(to: url, executor: executor)
    }

    /// Builds an interactive-console controller bound to the live document. The
    /// console runs each submission against a temp `.usda` copy of the current
    /// stage (written via the pure-Swift serializer), re-opens the result through
    /// the bridge, and records any change as one undoable command. Returns nil
    /// when there's no document or no Python interpreter.
    @MainActor
    private func makeConsoleController() -> ReplController? {
        guard let document,
              let bridge = ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath),
              let executor = ProcessScriptExecutor(
                bridge: ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath))
        else { return nil }

        let workingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusdz-console-\(UUID().uuidString).usda")
        let selection = document.selection.paths.map(\.description)
        let session = ReplSession(
            executor: executor,
            context: ReplContext(inputPath: workingURL.path, selection: selection))

        return ReplController(
            session: session,
            workingURL: workingURL,
            liveSnapshot: { [weak document] in document?.snapshot ?? .init() },
            writeSnapshot: { snapshot, url in
                try await StageSaver.save(snapshot, to: url, executor: nil)
            },
            readSnapshot: { url in
                try await BridgedStage.open(url: url, executor: bridge).snapshot
            },
            commit: { [weak document] after, label in
                document?.applyConsoleEdit(after: after, label: label)
            })
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "usdz"),
                                     .init(filenameExtension: "usda"),
                                     .init(filenameExtension: "usdc"),
                                     .init(filenameExtension: "usd")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Re-imports a script-produced file into the scene: snapshots it through
    /// the bridge (behind the same import veil) and replaces the live document.
    /// Awaitable so a script runner can mark itself finished once the scene has
    /// actually updated.
    @MainActor
    private func reimport(_ url: URL) async {
        isImporting = true
        importingFileName = url.lastPathComponent
        defer {
            isImporting = false
            importingFileName = nil
        }
        do {
            guard let executor = Self.sharedOpenExecutor else {
                throw BridgeError.pythonUnavailable(detail: "no Python interpreter found")
            }
            let snapshot = try await BridgedStage.open(url: url, executor: executor).snapshot
            document = makeSessionedDocument(snapshot: snapshot, modelURL: url)
        } catch {
            let bridgeError = error as? BridgeError
            openError = [bridgeError?.errorDescription, bridgeError?.recoverySuggestion]
                .compactMap(\.self).joined(separator: "\n\n")
            if openError?.isEmpty != false { openError = error.localizedDescription }
        }
    }

    private func open(_ url: URL) {
        Task { @MainActor in
            isImporting = true
            importingFileName = url.lastPathComponent
            defer {
                isImporting = false
                importingFileName = nil
            }
            do {
                guard let executor = Self.sharedOpenExecutor else {
                    throw BridgeError.pythonUnavailable(detail: "no Python interpreter found")
                }
                let snapshot = try await BridgedStage.open(url: url, executor: executor).snapshot
                document = makeSessionedDocument(snapshot: snapshot, modelURL: url)
            } catch {
                let bridgeError = error as? BridgeError
                openError = [bridgeError?.errorDescription, bridgeError?.recoverySuggestion]
                    .compactMap(\.self).joined(separator: "\n\n")
                if openError?.isEmpty != false { openError = error.localizedDescription }
            }
        }
    }

    // MARK: Session restoration

    /// Builds a document over a fresh WAL session (so its edits survive a
    /// relaunch) and captures the initial envelope. Used by every open/import.
    @MainActor
    private func makeSessionedDocument(snapshot: StageSnapshot, modelURL: URL?) -> EditorDocument {
        // A normal open supersedes any pending restore hand-off, so stale
        // shell-owned state is never reapplied to a different document.
        restoredViewStateToApply = nil
        let journal = session.begin(for: modelURL)
        let doc = EditorDocument(snapshot: snapshot, modelURL: modelURL, journal: journal)
        session.attach(doc)
        session.capture(doc)
        return doc
    }

    /// File ▸ "Reset Session": wipes all session-restoration state (the active
    /// WAL plus any recoverable leftovers), then re-arms crash-safety for the
    /// still-open document by starting a fresh journaled session over its current
    /// scene. Rebuilding the document from its live snapshot is what re-attaches a
    /// new WAL to the command stack; the trade-off is that undo history resets —
    /// acceptable for an explicit "reset". Any pending restore hand-off is
    /// dropped. No document open → the reset alone is the whole effect.
    @MainActor
    private func resetSession() {
        session.reset()
        restoreCandidate = nil
        restoredDocument = nil
        restoredViewStateToApply = nil
        guard let current = document else { return }
        document = makeSessionedDocument(snapshot: current.snapshot, modelURL: current.modelURL)
    }

    /// On launch, if a previous session left unsaved work, rebuild its document
    /// and raise the restore prompt. Saved-and-quit sessions (no WAL work) are
    /// swept silently. Recovery is bounded and best-effort: a document that can't
    /// be rebuilt is discarded rather than blocking launch.
    @MainActor
    private func offerSessionRestore() async {
        guard let recoverable = session.findRecoverable() else { return }
        guard recoverable.plan.hasWork else { session.discard(recoverable); return }
        guard let rebuilt = await buildRestoredDocument(recoverable) else {
            session.discard(recoverable)
            return
        }
        restoreCandidate = recoverable
        restoredDocument = rebuilt
        showRestorePrompt = true
    }

    /// Resolves the last-saved baseline (reopened from the file via the bridge,
    /// or the embedded scratch snapshot) and replays the WAL to rebuild the
    /// document. `nil` when the baseline can't be obtained.
    @MainActor
    private func buildRestoredDocument(_ recoverable: SessionController.Recoverable) async -> EditorDocument? {
        if let url = recoverable.document.source?.resolve() {
            guard let executor = Self.sharedOpenExecutor,
                  let baseline = try? await BridgedStage.open(url: url, executor: executor).snapshot
            else { return nil }
            return session.restore(recoverable, baseline: baseline)
        }
        guard let baseline = session.embeddedBaseline(for: recoverable) else { return nil }
        return session.restore(recoverable, baseline: baseline)
    }

    /// The restore prompt's body: how many unsaved edits, and a caution when the
    /// underlying file changed on disk since the session was captured.
    private var restorePromptMessage: String {
        guard let recoverable = restoreCandidate else { return "" }
        let name = recoverable.displayName ?? "your last scene"
        var message = "You had unsaved changes to \(name) when the app last closed."
        if recoverable.sourceChangedOnDisk {
            message += "\n\n⚠︎ The file has changed on disk since then, so restored edits may not line up."
        }
        return message
    }

    /// Resolution order: explicit env override → bundled resource (packaged
    /// `.app` built via the Xcode project) → walk up from the cwd (`swift run`
    /// from the repo). This lets the same code path serve both the dev binary
    /// and the shipped bundle.
    static var snapshotScriptPath: String {
        if let override = ProcessInfo.processInfo.environment["DICYANIN_SNAPSHOT_SCRIPT"],
           !override.isEmpty {
            return override
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Python/stage_snapshot.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Python/stage_snapshot.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            dir.deleteLastPathComponent()
        }
        return "Resources/Python/stage_snapshot.py"
    }

    /// The long-lived worker script, shipped beside the one-shot snapshot script.
    static var serverScriptPath: String {
        URL(fileURLWithPath: snapshotScriptPath)
            .deletingLastPathComponent()
            .appendingPathComponent("bridge_server.py").path
    }

    /// One resident Python interpreter for the whole app session. Every Open…
    /// and script re-import reuses it, so `import pxr` (hundreds of ms) is paid
    /// once per launch instead of once per file. `nil` when no interpreter with
    /// usd-core is present, exactly like the one-shot executor; each open falls
    /// back to a fresh subprocess if the resident worker ever dies mid-session.
    static let sharedOpenExecutor: PersistentBridgeExecutor? =
        PersistentBridgeExecutor(serverScriptPath: serverScriptPath)
}
