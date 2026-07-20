import Foundation
import Observation
import USDCore
import ScriptingKit

/// Drives the interactive Python **console** (REPL) for the UI — the counterpart
/// to `ScriptRunController`'s one-shot script runs (ROADMAP Milestone 5).
///
/// Each completed submission runs as one interpreter process against a file copy
/// of the live stage, and its result is recorded as exactly one undoable command
/// (the "single-undo script run" contract). Orchestration lives here, behind
/// injected seams, so the whole console is exercised in unit tests with no Python
/// and no real files; the SwiftUI panel stays a thin renderer of this state.
///
/// Flow per submission:
///  1. Write the live snapshot to the session's working file (so the console
///     always sees current document state).
///  2. Feed the line to the `ReplSession`; a multi-line submission buffers until
///     complete.
///  3. On completion, re-open the working file and hand the result to `commit`,
///     which pushes a single `ReplaceStageCommand` when the stage actually changed.
@MainActor
@Observable
public final class ReplController {

    /// One rendered transcript row (stable id for SwiftUI `ForEach`).
    public struct Line: Identifiable, Equatable {
        public let id: Int
        public let entry: ReplEntry
    }

    public private(set) var transcript: [Line] = []
    /// The buffered source of an in-progress multi-line submission (for the
    /// continuation prompt); empty when not mid-submission.
    public private(set) var pending: String = ""
    /// `true` while an interpreter run is in flight (disables the prompt).
    public private(set) var isRunning = false
    /// `true` when the last line was buffered and a continuation is expected.
    public private(set) var needsContinuation = false

    /// Writes the live snapshot to the console's working file.
    public typealias SnapshotWriter = @Sendable (StageSnapshot, URL) async throws -> Void
    /// Re-opens the working file into a snapshot after a run.
    public typealias SnapshotReader = @Sendable (URL) async throws -> StageSnapshot

    private let session: ReplSession
    private let workingURL: URL
    private let liveSnapshot: @MainActor () -> StageSnapshot
    private let writeSnapshot: SnapshotWriter
    private let readSnapshot: SnapshotReader
    private let commit: @MainActor (_ after: StageSnapshot, _ label: String) -> Void
    private var counter = 0
    /// Surfaced when the working file couldn't be written/re-opened — a console
    /// edit that silently failed to persist would be worse than a visible error.
    public private(set) var ioError: String?

    public init(session: ReplSession,
                workingURL: URL,
                liveSnapshot: @escaping @MainActor () -> StageSnapshot,
                writeSnapshot: @escaping SnapshotWriter,
                readSnapshot: @escaping SnapshotReader,
                commit: @escaping @MainActor (_ after: StageSnapshot, _ label: String) -> Void) {
        self.session = session
        self.workingURL = workingURL
        self.liveSnapshot = liveSnapshot
        self.writeSnapshot = writeSnapshot
        self.readSnapshot = readSnapshot
        self.commit = commit
    }

    /// Submits one line of input. Buffers multi-line blocks, runs a completed
    /// submission as one process, appends the transcript, and records any stage
    /// change as one undoable command.
    public func submit(line: String) async {
        ioError = nil
        // Sync the working file to the live stage before a run so the console
        // sees current document state. A write failure aborts before running.
        let snapshot = liveSnapshot()
        do {
            try await writeSnapshot(snapshot, workingURL)
        } catch {
            ioError = "Couldn't stage the document for the console: \(error)"
            return
        }

        isRunning = true
        let result = await session.submit(line: line)
        isRunning = false

        switch result {
        case .needsMore:
            needsContinuation = true
            pending = await session.pendingSource()
        case .evaluated(let entry):
            needsContinuation = false
            pending = ""
            transcript.append(Line(id: counter, entry: entry))
            counter += 1
            await recordEdit(from: entry)
        }
    }

    /// Re-opens the working file and, when the submission mutated the stage,
    /// hands the new snapshot to `commit`. Errors on read are surfaced but never
    /// discard the transcript entry.
    private func recordEdit(from entry: ReplEntry) async {
        // A submission that raised didn't cleanly author anything; don't try to
        // fold a half-applied edit back in.
        guard !entry.isError else { return }
        do {
            let after = try await readSnapshot(workingURL)
            commit(after, label(for: entry.input))
        } catch {
            ioError = "Couldn't read back the console's changes: \(error)"
        }
    }

    /// A compact, single-line label for Edit ▸ Undo, e.g. `Console: stage.Save()`.
    func label(for source: String) -> String {
        let firstLine = source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? source
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let clipped = trimmed.count > 40 ? String(trimmed.prefix(39)) + "…" : trimmed
        return clipped.isEmpty ? "Console" : "Console: \(clipped)"
    }

    /// Up-arrow history recall (older).
    public func recallPrevious() async -> String? { await session.recallPrevious() }
    /// Down-arrow history recall (newer).
    public func recallNext() async -> String? { await session.recallNext() }
}
