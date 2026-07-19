import SwiftUI
import UniformTypeIdentifiers
import ScriptingKit
import DicyaninDesignSystem

/// Script library panel. Lists bundled starter scripts plus any the user adds,
/// previews source, and — via the Run button — executes the selected script
/// against the open document through `ScriptRunController`, streaming live
/// progress and re-importing the result into the scene.
struct ScriptsPanel: View {
    let onClose: () -> Void

    /// The open document's source file — the input a mutating script edits.
    var inputURL: URL?
    /// Builds the interpreter-backed executor (nil when no Python is available).
    var makeExecutor: () -> (any ScriptExecuting)? = { nil }
    /// Re-imports a script-produced file into the scene.
    var onReimport: (URL) async -> Void = { _ in }

    @State private var entries: [ScriptEntry] = []
    @State private var selected: ScriptEntry?
    @State private var source: String = ""
    @State private var runSession: RunSession?
    @State private var runUnavailable: String?

    /// Identifiable wrapper so a nested `.sheet(item:)` presents the run UI.
    private struct RunSession: Identifiable {
        let id = UUID()
        let controller: ScriptRunController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.panelBorder.color)
            HSplitView {
                list.frame(minWidth: 180, idealWidth: 220)
                preview.frame(minWidth: 260, maxWidth: .infinity)
            }
        }
        .frame(width: 640, height: 460)
        .background(Palette.windowBackground.color)
        .onAppear(perform: reload)
        .sheet(item: $runSession) { session in
            ScriptRunSheet(controller: session.controller) { runSession = nil }
        }
        .alert("Can't Run Script", isPresented: Binding(
            get: { runUnavailable != nil }, set: { if !$0 { runUnavailable = nil } })) {
            Button("OK") { runUnavailable = nil }
        } message: {
            Text(runUnavailable ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Scripts")
                .font(.system(size: TypeScale.title, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.color)
            Spacer()
            Button {
                startRun()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected == nil)
            .accessibilityIdentifier("scripts.runSelected")
            Button("Add…", action: addScripts)
            Button("Close", action: onClose)
        }
        .padding(Spacing.sm)
    }

    /// Builds a run controller for the selected script and presents the run
    /// sheet, or explains why it can't (no interpreter located).
    private func startRun() {
        guard let entry = selected else { return }
        guard let executor = makeExecutor() else {
            runUnavailable = "No Python interpreter with usd-core was found — "
                + "the same dependency as Open…. Install it, then try again."
            return
        }
        let controller = ScriptRunController(
            entry: entry, inputURL: inputURL, executor: executor,
            onReimport: onReimport)
        runSession = RunSession(controller: controller)
    }

    private var list: some View {
        List(ScriptLibrary.sorted(entries), selection: Binding(
            get: { selected },
            set: { newValue in selected = newValue; load(newValue) }
        )) { entry in
            HStack(spacing: Spacing.xs) {
                Image(systemName: entry.isBundled ? "shippingbox" : "doc.text")
                    .foregroundStyle(Palette.textSecondary.color)
                Text(entry.displayName)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textPrimary.color)
                if entry.isBundled { Spacer(); miniBadge("bundled") }
            }
            .tag(entry)
        }
        .listStyle(.sidebar)
        .overlay {
            if entries.isEmpty {
                Text("No scripts yet.\nAdd a .py file to get started.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
    }

    private var preview: some View {
        ScrollView {
            Text(source.isEmpty ? "Select a script to preview its source." : source)
                .font(.system(size: TypeScale.inspectorField, design: .monospaced))
                .foregroundStyle(source.isEmpty ? Palette.textSecondary.color : Palette.textPrimary.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm)
        }
        .background(Palette.viewportBackground.color)
    }

    private func miniBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Palette.accent.color.opacity(0.18)))
            .foregroundStyle(Palette.accent.color)
    }

    // MARK: Data

    private func reload() {
        entries = ScriptLibrary.sorted(bundledScripts() + entries.filter { !$0.isBundled })
    }

    /// Bundled starter scripts shipped in Resources/Python/scripts (dev-run
    /// walks up from cwd; the packaged app carries them in bundle resources).
    private func bundledScripts() -> [ScriptEntry] {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Python/scripts")
            if let urls = try? FileManager.default.contentsOfDirectory(
                at: candidate, includingPropertiesForKeys: nil) {
                return ScriptLibrary.scripts(from: urls, bundled: true)
            }
            dir.deleteLastPathComponent()
        }
        return []
    }

    private func addScripts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "py")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = ScriptLibrary.scripts(from: panel.urls, bundled: false)
        entries = ScriptLibrary.sorted(entries + added)
    }

    private func load(_ entry: ScriptEntry?) {
        guard let entry else { source = ""; return }
        source = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? "// could not read \(entry.url.lastPathComponent)"
    }
}
