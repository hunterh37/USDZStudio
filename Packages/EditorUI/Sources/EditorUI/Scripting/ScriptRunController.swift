import Foundation
import Observation
import ScriptingKit

/// Drives a single script run for the UI: loads the manifest, holds the
/// parameter values, runs the script, and republishes live progress/log so a
/// SwiftUI sheet can render a play button, a determinate progress bar, and a
/// console — then hands the produced file back for re-import.
@MainActor
@Observable
public final class ScriptRunController {

    public enum Phase: Equatable {
        case loadingManifest
        case ready                    // manifest loaded, awaiting Run
        case running
        case succeeded(reimported: Bool)
        case failed(String)
    }

    public let entry: ScriptEntry
    /// The file the script operates on (the open document's source file).
    public let inputURL: URL?

    public private(set) var phase: Phase = .loadingManifest
    public private(set) var manifest: ScriptManifest?

    /// Editable parameter values keyed by argument name, seeded from defaults.
    public var argumentValues: [String: String] = [:]
    public var dryRun: Bool = false

    public private(set) var progressFraction: Double?
    public private(set) var progressMessage: String = ""
    public private(set) var logLines: [String] = []

    private let runner: ScriptRunner
    /// Invoked with the produced file when a mutating run finishes, so the app
    /// can re-import it into the scene.
    private let onReimport: (URL) async -> Void

    public init(entry: ScriptEntry,
                inputURL: URL?,
                executor: any ScriptExecuting,
                onReimport: @escaping (URL) async -> Void) {
        self.entry = entry
        self.inputURL = inputURL
        self.runner = ScriptRunner(executor: executor)
        self.onReimport = onReimport
    }

    /// Whether a run can start: manifest present, not already running, and —
    /// for a mutating script — a file to operate on.
    public var canRun: Bool {
        guard let manifest else { return false }
        if case .running = phase { return false }
        if manifest.mutates && !dryRun && inputURL == nil { return false }
        return true
    }

    public func loadManifest() async {
        phase = .loadingManifest
        do {
            let loaded = try await runner.loadManifest(script: entry.url)
            manifest = loaded
            seedDefaults(from: loaded)
            phase = .ready
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func seedDefaults(from manifest: ScriptManifest) {
        for argument in manifest.arguments {
            if let value = argument.defaultValue {
                argumentValues[argument.name] = value.displayString
            } else {
                argumentValues[argument.name] = ""
            }
        }
    }

    public func run() async {
        guard let manifest, canRun else { return }
        guard let inputURL else {
            phase = .failed("Open a file before running a script that edits the stage.")
            return
        }
        phase = .running
        progressFraction = manifest.mutates ? 0 : nil
        progressMessage = ""
        logLines = []

        let options = ScriptRunOptions(dryRun: dryRun, argumentValues: argumentValues)
        do {
            let result = try await runner.run(
                script: entry.url, manifest: manifest, input: inputURL,
                options: options,
                onEvent: { [weak self] event in
                    Task { @MainActor in self?.ingest(event) }
                })
            // Fold in stdout (reports) as trailing log lines.
            appendReport(result.standardOutput)

            if let output = result.outputURL {
                progressFraction = 1
                await onReimport(output)
                phase = .succeeded(reimported: true)
            } else {
                phase = .succeeded(reimported: false)
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func ingest(_ event: ScriptRunEvent) {
        switch event {
        case .progress(let p):
            progressFraction = p.fraction
            if !p.message.isEmpty { progressMessage = p.message }
        case .log(let line):
            logLines.append(line)
        }
    }

    private func appendReport(_ stdout: String) {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(contentsOf: trimmed.components(separatedBy: "\n"))
    }

    static func message(for error: Error) -> String {
        if let runError = error as? ScriptRunError { return runError.description }
        if let execError = error as? ScriptExecutorError { return execError.description }
        return String(describing: error)
    }
}
