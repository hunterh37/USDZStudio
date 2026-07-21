import Foundation
import USDCore

/// Everything needed to restore one open document across a relaunch, *except*
/// the write-ahead log — the WAL and its per-session directory lifecycle are
/// owned by `EditingKit.SessionStore` (crash sentinel, `recoverableSessions`,
/// `RecoveryPlan`). This is the higher-level envelope that lives alongside that
/// WAL in the same session directory: which file was open, its on-disk identity,
/// and the transient view state.
///
/// A document is restored by reopening its `source` file (or, for a never-saved
/// scratch scene, decoding the `embeddedSnapshot`) to get the last-saved
/// baseline, then replaying the EditingKit WAL to rebuild the exact undo/redo
/// history, then applying `viewState`.
public struct DocumentSession: Equatable, Codable, Sendable {
    /// The backing file, or `nil` for a scratch scene never written to disk.
    public var source: SourceReference?
    /// Fingerprint of `source` at capture time, for change detection. `nil` for
    /// scratch scenes.
    public var fingerprint: SourceFingerprint?
    /// The stack revision that was last saved to disk — drives the unsaved-edit
    /// indication shown in the restore prompt.
    public var savedRevision: Int
    /// For a scratch scene with no `source`, the full serialized stage so it can
    /// be restored without a file. `nil` for file-backed documents.
    public var embeddedSnapshot: StageSnapshot?
    /// Transient per-document view/UI state.
    public var viewState: ViewState

    public init(
        source: SourceReference? = nil,
        fingerprint: SourceFingerprint? = nil,
        savedRevision: Int = 0,
        embeddedSnapshot: StageSnapshot? = nil,
        viewState: ViewState = ViewState()
    ) {
        self.source = source
        self.fingerprint = fingerprint
        self.savedRevision = savedRevision
        self.embeddedSnapshot = embeddedSnapshot
        self.viewState = viewState
    }

    /// `true` when the backing file changed on disk since capture (or is gone),
    /// so a WAL replay would build on a stale baseline. `false` for scratch
    /// scenes (nothing to compare against) and unchanged files.
    public func sourceChangedOnDisk() -> Bool {
        guard let fingerprint, let url = source?.resolve() else { return false }
        return !fingerprint.matches(fileAt: url)
    }
}
