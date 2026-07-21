import Foundation
import USDCore
import EditingKit
import ViewportKit
import SessionKit

/// Bridges the live editor document and its transient view state to and from the
/// serializable `SessionKit` types (specs/session-restoration.md).
///
/// The mapping is split by ownership: this file handles the *document-owned* view
/// state (selection, gizmo modes, isolate roots) and assembles the descriptor;
/// *shell-owned* state (camera, environment, panels, outliner expansion) is
/// passed in by the shell, which holds it as `@State`.

public extension ViewState {
    /// Captures a document's view state. Document-owned fields are read directly;
    /// shell-owned fields are supplied by the caller.
    @MainActor
    static func capture(
        from document: EditorDocument,
        collapsed: Set<PrimPath> = [],
        camera: ViewportCameraPose? = nil,
        environment: EnvironmentSettings? = nil,
        panelVisibility: [String: Bool] = [:],
        playbackPosition: Double? = nil
    ) -> ViewState {
        ViewState(
            selectionPaths: document.selection.paths.map(\.description),
            primarySelectionPath: document.selection.primary?.description,
            collapsedPaths: collapsed.map(\.description),
            gizmoMode: document.gizmoMode.rawValue,
            gizmoOrientation: document.gizmoOrientation.rawValue,
            gizmoPivotMode: document.gizmoPivotMode.rawValue,
            isolationRoots: document.isolation.roots.map(\.description),
            panelVisibility: panelVisibility,
            camera: camera.map(CameraState.init(pose:)),
            environment: environment,
            playbackPosition: playbackPosition)
    }

    /// The restored outliner-collapsed set, keeping only paths still on `stage`.
    func restoredCollapsed(in snapshot: StageSnapshot) -> Set<PrimPath> {
        Set(collapsedPaths.compactMap(PrimPath.init).filter { snapshot.prim(at: $0) != nil })
    }

    /// The restored camera pose, if one was captured.
    var restoredCameraPose: ViewportCameraPose? { camera?.pose }
}

public extension DocumentSession {
    /// Builds a session descriptor for a live document (the WAL itself is owned
    /// by `EditingKit.SessionStore`; this is the envelope stored beside it). A
    /// file-backed document records a `SourceReference` + on-disk
    /// `SourceFingerprint`; a never-saved scratch scene embeds its full snapshot
    /// instead.
    /// - Parameter embeddedBaseline: for a scratch scene (no file), the snapshot
    ///   the WAL replays onto — the state at the last checkpoint, *not* the live
    ///   edited snapshot (replaying the WAL onto the edited state would
    ///   double-apply). Ignored for file-backed documents, whose baseline is the
    ///   file itself. The `SessionController` captures this once when the
    ///   document is attached.
    @MainActor
    static func capture(
        document: EditorDocument,
        embeddedBaseline: StageSnapshot?,
        collapsed: Set<PrimPath> = [],
        camera: ViewportCameraPose? = nil,
        environment: EnvironmentSettings? = nil,
        panelVisibility: [String: Bool] = [:],
        playbackPosition: Double? = nil
    ) -> DocumentSession {
        let url = document.modelURL
        let viewState = ViewState.capture(
            from: document, collapsed: collapsed, camera: camera,
            environment: environment, panelVisibility: panelVisibility,
            playbackPosition: playbackPosition)
        return DocumentSession(
            source: url.map { SourceReference(url: $0) },
            fingerprint: url.flatMap { try? SourceFingerprint.make(for: $0) },
            savedRevision: document.savedRevision,
            embeddedSnapshot: url == nil ? embeddedBaseline : nil,
            viewState: viewState)
    }
}

public extension EditorDocument {
    /// Applies the *document-owned* parts of a restored view state: selection
    /// (primary first), gizmo modes, and isolate roots. Only paths that still
    /// exist on the current stage are restored, and an unknown gizmo enum value
    /// is ignored rather than reset — so a session written by a different build
    /// degrades gracefully. Shell-owned state (camera, environment, panels,
    /// outliner expansion) is applied by the shell.
    func applySessionViewState(_ viewState: ViewState) {
        var ordered: [PrimPath] = []
        if let primary = viewState.primarySelectionPath.flatMap(PrimPath.init),
           snapshot.prim(at: primary) != nil {
            ordered.append(primary)
        }
        for path in viewState.selectionPaths.compactMap(PrimPath.init) where
            snapshot.prim(at: path) != nil && !ordered.contains(path) {
            ordered.append(path)
        }
        selection = Selection(ordered)

        if let mode = viewState.gizmoMode.flatMap(GizmoMode.init(rawValue:)) { gizmoMode = mode }
        if let orientation = viewState.gizmoOrientation.flatMap(GizmoOrientation.init(rawValue:)) {
            gizmoOrientation = orientation
        }
        if let pivot = viewState.gizmoPivotMode.flatMap(GizmoPivot.init(rawValue:)) {
            gizmoPivotMode = pivot
        }

        let roots = viewState.isolationRoots.compactMap(PrimPath.init)
            .filter { snapshot.prim(at: $0) != nil }
        if !roots.isEmpty { restoreIsolation(roots) }
    }

    /// Rebuilds a document from a session descriptor and an already-resolved
    /// last-saved `baseline` (file-backed baselines are opened via the bridge by
    /// the caller; a scratch scene passes `session.embeddedSnapshot`). Replays the
    /// WAL `records` (from `EditingKit.SessionStore.RecoveryPlan`) to restore
    /// undo/redo history, continuing to append to `journal`, then applies the
    /// document-owned view state. Replay failure falls back to a clean journaled
    /// open of the baseline so restoration can never fail outright.
    static func restore(
        session: DocumentSession,
        baseline: StageSnapshot,
        journal: (any CommandJournal)?,
        records: [JournalRecord]
    ) -> EditorDocument {
        let modelURL = session.source?.resolve()
        let document = (try? EditorDocument.restored(
            baseline: baseline, modelURL: modelURL, journal: journal, records: records))
            ?? EditorDocument(snapshot: baseline, modelURL: modelURL, journal: journal)
        document.applySessionViewState(session.viewState)
        return document
    }
}
