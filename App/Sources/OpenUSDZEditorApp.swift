import SwiftUI
import EditorUI
import USDBridge
import USDCore
import ScriptingKit

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
        // Remove the activity-endpoint discovery file so a later-spawned server
        // doesn't try to reach a dead port.
        try? FileManager.default.removeItem(at: MCPActivityListener.endpointURL())
    }
}

@main
struct OpenUSDZEditorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var document: EditorDocument?
    @State private var openError: String?

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
                            makeScriptExecutor: {
                                ProcessScriptExecutor(
                                    bridge: ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath))
                            },
                            onReimportFile: { url in await reimport(url) },
                            onCreateDocument: {
                                // Start a fresh, empty scratch scene (no backing
                                // file) so the library can add primitives without
                                // opening a file first.
                                let doc = EditorDocument()
                                document = doc
                                return doc
                            })
                .frame(minWidth: 1000, minHeight: 620)
                .alert("Could Not Open File", isPresented: .constant(openError != nil)) {
                    Button("OK") { openError = nil }
                } message: {
                    Text(openError ?? "")
                }
                .onOpenURL(perform: open)
                .task {
                    // Start the localhost activity listener + write the
                    // endpoint-discovery file so `openusdz mcp` can connect.
                    mcp.start()
                    // Dev convenience: `swift run OpenUSDZEditorApp file.usda`
                    // opens straight into the file.
                    if document == nil,
                       let arg = CommandLine.arguments.dropFirst().first(where: {
                           ["usda", "usdz", "usdc", "usd"].contains(URL(fileURLWithPath: $0).pathExtension)
                       }) {
                        open(URL(fileURLWithPath: arg))
                    }
                    // First run, nothing open: show the guided tour.
                    if document == nil && !hasSeenTutorial {
                        startTutorial()
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in open(url) } }
                    }
                    return true
                }
        }
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
                Divider()
                Button("Convert File…") { postMenu(.convert) }
                    .keyboardShortcut("k")
                Button("Batch Convert…") { postMenu(.batch) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Validate Stage") { postMenu(.validate) }
                    .keyboardShortcut("u")
                    .disabled(document == nil)
                Button("Scripts…") { postMenu(.scripts) }
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
            guard let executor = ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath) else {
                throw BridgeError.pythonUnavailable(detail: "no Python interpreter found")
            }
            let snapshot = try await BridgedStage.open(url: url, executor: executor).snapshot
            document = EditorDocument(snapshot: snapshot, modelURL: url)
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
                guard let executor = ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath) else {
                    throw BridgeError.pythonUnavailable(detail: "no Python interpreter found")
                }
                let snapshot = try await BridgedStage.open(url: url, executor: executor).snapshot
                document = EditorDocument(snapshot: snapshot, modelURL: url)
            } catch {
                let bridgeError = error as? BridgeError
                openError = [bridgeError?.errorDescription, bridgeError?.recoverySuggestion]
                    .compactMap(\.self).joined(separator: "\n\n")
                if openError?.isEmpty != false { openError = error.localizedDescription }
            }
        }
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
}
