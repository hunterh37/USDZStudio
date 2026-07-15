import Foundation
import Observation
import USDCore
import EditingKit
import ValidationKit

/// The editor's live, mutable document — the single source of truth once a file
/// is open.
///
/// It owns an ``InMemoryStage`` (the value-backed mutable stage) and a
/// ``CommandStack``, and republishes a fresh ``StageSnapshot`` after every
/// mutation so SwiftUI views (outliner, inspector, viewport HUD) recompute. All
/// edits — from the inspector, outliner, or a gizmo drag — flow through the
/// convenience methods here so they are uniformly undoable.
///
/// `@Observable` + `@MainActor`: mutations happen on the main thread, and the
/// `CommandStack.onChange` hook (which also fires when AppKit's undo manager
/// replays a command) refreshes the published snapshot.
///
/// Undo/redo is driven directly through this document (`undo()` / `redo()`),
/// which the App exposes as Edit-menu commands. `UndoManagerBridge` remains the
/// package seam for the eventual `NSDocument`-based architecture; it is not
/// wired here to keep a single, deterministic undo path in the windowed dev app.
@MainActor
@Observable
public final class EditorDocument {

    /// Source file for the viewport's RealityKit fast path (nil for a scratch stage).
    public let modelURL: URL?

    /// The current composed state, refreshed after every command. Views read this.
    public private(set) var snapshot: StageSnapshot

    /// The active selection (multi-select; part-level semantics per PRD §5.3).
    public var selection: Selection = .empty

    /// Snapping shared by the numeric inspector fields and the viewport gizmo.
    public var snap: SnapSettings = .off

    /// Bumped on every stack change so the menu can observe undo/redo enablement.
    public private(set) var revision: Int = 0

    private let stage: InMemoryStage
    private let stack: CommandStack

    public init(snapshot: StageSnapshot = StageSnapshot(), modelURL: URL? = nil) {
        self.modelURL = modelURL
        self.snapshot = snapshot
        let stage = InMemoryStage(snapshot)
        self.stage = stage
        self.stack = CommandStack(stage: stage)
        self.stack.onChange = { [weak self] in
            // Runs synchronously on the calling (main) thread — mirrors the
            // UndoManagerBridge's own assumeIsolated pattern.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Undo/redo surface

    public var canUndo: Bool { stack.canUndo }
    public var canRedo: Bool { stack.canRedo }
    public var undoLabel: String? { stack.undoLabel }
    public var redoLabel: String? { stack.redoLabel }

    public func undo() { _ = try? stack.undo() }
    public func redo() { _ = try? stack.redo() }

    /// Runs a command, surfacing (but not throwing) mutation errors so a bad
    /// edit from the UI never crashes the app. Returns the applied label.
    @discardableResult
    public func run(_ command: any EditCommand) -> String? {
        do { return try stack.run(command) }
        catch { lastError = "\(error)"; return nil }
    }

    /// The most recent mutation error, for surfacing in the UI.
    public private(set) var lastError: String?
    public func clearError() { lastError = nil }

    // MARK: Prim edits

    /// Renames a prim and moves the selection to follow it. No-op if the name
    /// is unchanged.
    public func rename(_ path: PrimPath, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != path.name else { return }
        let command = RenamePrimCommand(path: path, newName: trimmed)
        guard run(command) != nil else { return }
        if selection.contains(path) {
            selection = selection.selecting(command.renamedPath)
        }
    }

    public func setActive(_ path: PrimPath, _ isActive: Bool) {
        guard let prim = snapshot.prim(at: path), prim.isActive != isActive else { return }
        run(SetActiveCommand(path: path, newValue: isActive, oldValue: prim.isActive))
    }

    public func setVisibility(_ path: PrimPath, _ visibility: Visibility) {
        guard let prim = snapshot.prim(at: path), prim.visibility != visibility else { return }
        run(SetVisibilityCommand(path: path, newVisibility: visibility, oldVisibility: prim.visibility))
    }

    /// Deletes a prim (and its subtree), capturing enough context to undo.
    public func delete(_ path: PrimPath) {
        guard let (prim, parent, index) = locate(path) else { return }
        run(RemovePrimCommand(prim: prim, parent: parent, index: index))
        if selection.contains(path) { selection = .empty }
    }

    // MARK: Structural edits

    /// Duplicates a prim as a sibling and selects the copy.
    public func duplicate(_ path: PrimPath) {
        guard let command = DuplicatePrimCommand.make(path: path, in: snapshot) else { return }
        guard run(command) != nil else { return }
        selection = selection.selecting(command.duplicatePath)
    }

    /// Moves a prim under `newParent` (root when `nil`), preserving its world
    /// transform, and follows it with the selection.
    public func reparent(_ path: PrimPath, under newParent: PrimPath?) {
        guard let command = ReparentPrimCommand.make(path: path, under: newParent, in: snapshot) else { return }
        guard run(command) != nil else { return }
        if selection.contains(path) { selection = selection.selecting(command.moved.path) }
    }

    /// Groups sibling prims under a new `Xform` and selects the group.
    public func group(_ paths: [PrimPath], named name: String = "Group") {
        guard let command = GroupPrimsCommand.make(paths: paths, named: name, in: snapshot) else { return }
        guard run(command) != nil else { return }
        selection = Selection([command.groupPath])
    }

    /// Groups the current multi-selection (a no-op for < 2 prims or mixed parents).
    public func groupSelection(named name: String = "Group") {
        guard selection.paths.count >= 1 else { return }
        group(selection.paths, named: name)
    }

    // MARK: Transform edits

    /// The prim's local transform as an editable TRS.
    public func transform(at path: PrimPath) -> TRS { snapshot.transform(at: path) }

    /// Commits a transform edit (one undo entry). `verb` labels the menu item.
    public func setTransform(_ path: PrimPath, to trs: TRS, verb: String = "Transform") {
        let snapped = snap.apply(to: trs)
        let old = snapshot.prim(at: path)?.attribute(named: transformAttributeName)
        run(SetTransformCommand(path: path, newTRS: snapped, oldAttribute: old, verb: verb))
    }

    /// A live gizmo/field drag session against `path`, pre-seeded with the
    /// document's snapping. Feed it live values, then `commit(_:)` the result.
    public func makeDragSession(for path: PrimPath) -> TransformDragSession {
        TransformDragSession(stage: stage, path: path, snap: snap)
    }

    /// Records a finished drag as one coalesced undo entry (its live previews
    /// already mutated the stage; this makes the whole gesture undoable).
    public func commit(_ session: TransformDragSession, verb: String = "Transform") {
        guard let command = session.makeCommand(verb: verb) else { return }
        run(command)
    }

    // MARK: Stage metadata edits

    public func setStageMetadata(_ metadata: StageMetadata) {
        guard metadata != snapshot.metadata else { return }
        run(SetStageMetadataCommand(newMetadata: metadata, oldMetadata: snapshot.metadata))
    }

    // MARK: Validation quick-fixes

    /// The quick-fix for a diagnostic against the live stage, if one exists.
    public func quickFix(for diagnostic: Diagnostic) -> QuickFix? {
        QuickFixRegistry.quickFix(for: diagnostic, in: snapshot)
    }

    /// Applies a diagnostic's quick-fix as one undoable command. Returns `true`
    /// when a fix was available and ran.
    @discardableResult
    public func applyQuickFix(for diagnostic: Diagnostic) -> Bool {
        guard let fix = quickFix(for: diagnostic) else { return false }
        return run(fix.command) != nil
    }

    // MARK: Private

    private func refresh() {
        snapshot = stage.currentSnapshot
        revision &+= 1
    }

    /// Finds a prim plus its parent path and sibling index (for undoable delete).
    private func locate(_ path: PrimPath) -> (Prim, PrimPath?, Int)? {
        if let i = snapshot.rootPrims.firstIndex(where: { $0.path == path }) {
            return (snapshot.rootPrims[i], nil, i)
        }
        let parentPath = path.parent
        guard let parent = snapshot.prim(at: parentPath),
              let i = parent.children.firstIndex(where: { $0.path == path }) else { return nil }
        return (parent.children[i], parentPath, i)
    }
}
