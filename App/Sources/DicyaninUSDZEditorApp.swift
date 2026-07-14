import SwiftUI
import EditorUI
import USDBridge
import USDCore

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
}

@main
struct DicyaninUSDZEditorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var stage: StageSnapshot?
    @State private var modelURL: URL?
    @State private var openError: String?

    var body: some Scene {
        WindowGroup("Dicyanin USDZ Editor") {
            EditorShellView(stage: stage, modelURL: modelURL)
                .frame(minWidth: 1000, minHeight: 620)
                .alert("Could Not Open File", isPresented: .constant(openError != nil)) {
                    Button("OK") { openError = nil }
                } message: {
                    Text(openError ?? "")
                }
                .onOpenURL(perform: open)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { open(url) }
                    }
                    return true
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { presentOpenPanel() }
                    .keyboardShortcut("o")
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

    private func open(_ url: URL) {
        Task { @MainActor in
            do {
                guard let executor = ProcessBridgeExecutor(scriptPath: Self.snapshotScriptPath) else {
                    throw BridgeError.pythonUnavailable(detail: "no Python interpreter found")
                }
                stage = try await BridgedStage.open(url: url, executor: executor).snapshot
                modelURL = url
            } catch {
                let bridgeError = error as? BridgeError
                openError = [bridgeError?.errorDescription, bridgeError?.recoverySuggestion]
                    .compactMap(\.self).joined(separator: "\n\n")
                if openError?.isEmpty != false { openError = error.localizedDescription }
            }
        }
    }

    /// Resolved by walking up from the cwd for `swift run`; the packaged app
    /// will carry the script in its bundle resources (Phase 1).
    static var snapshotScriptPath: String {
        if let override = ProcessInfo.processInfo.environment["DICYANIN_SNAPSHOT_SCRIPT"],
           !override.isEmpty {
            return override
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
