import Foundation
import Observation
import USDCore
import EditingKit
import ViewportKit
import SessionKit

/// The app-session service: ties `EditingKit.SessionStore` (the per-document WAL
/// directory, crash sentinel, and recovery scan) to `SessionKit`'s envelope
/// (which file was open + the transient view state) so the app can capture and
/// restore a full working session across launches (specs/session-restoration.md).
///
/// A `Service` in the CLAUDE.md sense: side-effecting persistence behind an
/// injectable seam (both the WAL store and the envelope store are injected), so
/// it unit-tests against temp directories / in-memory backends without the app.
///
/// Lifecycle:
/// - `begin(for:)` when a document opens → a fresh WAL session; attach its
///   `journal` to the document's `CommandStack`, then `capture(_:)`.
/// - `capture(_:…)` on edits / scene-phase changes → rewrites the envelope
///   (the WAL already appends per command).
/// - `findRecoverable()` on launch → the newest session with a readable
///   envelope, if any, for the restore prompt.
/// - `restore(_:baseline:)` builds the document and adopts that session so
///   further captures continue to it.
/// - `discard(_:)` when the user declines; `endActive()` when a session is
///   superseded (a new document opened).
@Observable
@MainActor
public final class SessionController {

    /// A recoverable session found on launch: the WAL replay plan plus the
    /// decoded envelope (which file + view state).
    public struct Recoverable: Sendable {
        public let plan: EditingKit.SessionStore.RecoveryPlan
        public let document: DocumentSession
        /// `true` when the backing file changed on disk since capture — a WAL
        /// replay would build on a stale baseline, so the prompt should warn.
        public var sourceChangedOnDisk: Bool { document.sourceChangedOnDisk() }
        /// A short name for the restore prompt.
        public var displayName: String? { document.source?.displayName }
    }

    @ObservationIgnored private let sessions: EditingKit.SessionStore
    @ObservationIgnored private let envelopes: any EnvelopeStore

    /// The directory of the session captures currently write to (`nil` before a
    /// document is opened/restored).
    public private(set) var activeDirectory: URL?

    /// The live WAL session for a freshly opened document (absent for a restored
    /// session, whose directory is adopted directly).
    @ObservationIgnored private var activeSession: EditingKit.SessionStore.Session?

    /// For a scratch scene (no file), the snapshot the WAL replays onto — fixed
    /// at attach/restore time so later captures don't record the edited state as
    /// the baseline (which would double-apply on restore). `nil` for file-backed
    /// documents (their baseline is the file).
    @ObservationIgnored private var embeddedBaseline: StageSnapshot?

    public init(
        sessions: EditingKit.SessionStore = .defaultStore(),
        envelopes: any EnvelopeStore = FileEnvelopeStore()
    ) {
        self.sessions = sessions
        self.envelopes = envelopes
    }

    // MARK: Capture

    /// Starts a fresh WAL session for a newly opened document, superseding any
    /// active one. Returns the journal to attach to the document's `CommandStack`
    /// (`nil` only if the session directory couldn't be created). Follow with
    /// `capture(_:)` once the document exists.
    @discardableResult
    public func begin(for modelURL: URL?) -> FileCommandJournal? {
        endActive()
        guard let session = try? sessions.startSession(for: modelURL) else { return nil }
        activeSession = session
        activeDirectory = session.directory
        return session.journal
    }

    /// Records the just-built document's baseline: for a scratch scene, the
    /// pre-edit snapshot the WAL replays onto. Call once, right after building the
    /// document with the journal from `begin(for:)` and before any edits.
    public func attach(_ document: EditorDocument) {
        embeddedBaseline = document.modelURL == nil ? document.snapshot : nil
    }

    /// Rewrites the envelope for the active session from the live document + the
    /// shell-owned view state. No-op when there is no active session.
    public func capture(
        _ document: EditorDocument,
        collapsed: Set<PrimPath> = [],
        camera: ViewportCameraPose? = nil,
        environment: EnvironmentSettings? = nil,
        panelVisibility: [String: Bool] = [:],
        playbackPosition: Double? = nil
    ) {
        guard let activeDirectory else { return }
        let descriptor = DocumentSession.capture(
            document: document, embeddedBaseline: embeddedBaseline,
            collapsed: collapsed, camera: camera,
            environment: environment, panelVisibility: panelVisibility,
            playbackPosition: playbackPosition)
        try? envelopes.write(SessionEnvelope(document: descriptor), to: activeDirectory)
    }

    // MARK: Restore

    /// The newest recoverable session that has a readable envelope, or `nil` when
    /// there is nothing to offer. Sessions without an envelope (e.g. a bare
    /// crash-only WAL from before this feature) are skipped here — plain WAL
    /// crash recovery is a separate concern.
    public func findRecoverable() -> Recoverable? {
        for plan in sessions.recoverableSessions().reversed() {
            guard let envelope = envelopes.read(from: plan.directory) else { continue }
            return Recoverable(plan: plan, document: envelope.document)
        }
        return nil
    }

    /// Rebuilds the document for `recoverable` against an already-resolved
    /// `baseline` (opened from the file via the bridge, or the embedded scratch
    /// snapshot), adopts its session so further captures continue to the same
    /// directory/WAL, and returns the document.
    public func restore(_ recoverable: Recoverable, baseline: StageSnapshot) -> EditorDocument {
        let journal = try? sessions.journal(for: recoverable.plan)
        let document = EditorDocument.restore(
            session: recoverable.document, baseline: baseline,
            journal: journal, records: recoverable.plan.records)
        // Adopt the recovered session directory; its sentinel already marks it
        // live, so a re-crash after restore is still recoverable. Carry the
        // scratch baseline forward so continued captures replay correctly.
        activeSession = nil
        activeDirectory = recoverable.plan.directory
        embeddedBaseline = recoverable.document.embeddedSnapshot
        return document
    }

    /// The baseline snapshot for a scratch scene (no file) — the embedded stage.
    /// File-backed baselines are opened by the caller via the bridge.
    public func embeddedBaseline(for recoverable: Recoverable) -> StageSnapshot? {
        recoverable.document.embeddedSnapshot
    }

    // MARK: Teardown

    /// Drops a declined recoverable session.
    public func discard(_ recoverable: Recoverable) {
        sessions.discard(recoverable.plan)
    }

    /// Wipes all session state: ends the active WAL session and removes *every*
    /// on-disk session (the active one plus any recoverable leftovers from prior
    /// launches), so the next launch offers nothing to restore. Backs the
    /// File ▸ "Reset Session" command. After this the controller holds no active
    /// session; the caller re-arms crash-safety for the current document by
    /// starting a fresh session via `begin(for:)`.
    public func reset() {
        endActive()
        sessions.reset()
    }

    /// Ends the active session (a document was superseded). Kept out of the clean
    /// quit path on purpose: leaving the session on disk is what lets the next
    /// launch offer to restore it.
    public func endActive() {
        if let activeSession { sessions.finish(activeSession) }
        activeSession = nil
        activeDirectory = nil
    }
}
