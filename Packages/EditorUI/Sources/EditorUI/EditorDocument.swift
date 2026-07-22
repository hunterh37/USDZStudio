import Foundation
import Observation
import simd
import USDCore
import USDBridge
import DiagnosticsKit
import EditingKit
import ValidationKit
import ViewportKit

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

    /// The stage as last opened or saved — the reference the diff panel compares
    /// the live snapshot against ("what have I changed since I opened this?").
    /// Refreshed on every successful save so the diff always reads against the
    /// on-disk state.
    public private(set) var baselineSnapshot: StageSnapshot

    /// A structured diff of the live edits made since the file was opened or last
    /// saved. Empty when nothing has changed. Consumes the pure ``StageDiff``
    /// engine (also behind the CLI `diff` subcommand).
    public var diffFromBaseline: StageDiff {
        StageDiff.between(baselineSnapshot, snapshot)
    }

    /// The active selection (multi-select; part-level semantics per PRD §5.3).
    public var selection: Selection = .empty

    /// Snapping shared by the numeric inspector fields and the viewport gizmo.
    public var snap: SnapSettings = .off

    /// The active transform gizmo (W/E/R). Only the matching gizmo descriptor
    /// is published, so the viewport shows one manipulator at a time.
    public var gizmoMode: GizmoMode = .translate

    /// Whether the rotate/scale gizmos are drawn (and manipulated) in world or
    /// the selection's local basis. Translate is always world-axis.
    public var gizmoOrientation: GizmoOrientation = .world

    /// Where a multi-selection rotate/scale pivots: the shared median centroid
    /// (default) or each prim's own origin.
    public var gizmoPivotMode: GizmoPivot = .median

    /// Live mesh edit-mode state; `nil` in object mode (Phase 6,
    /// specs/mesh-editing.md). Managed by `EditorDocument+MeshEdit.swift`.
    public var meshEdit: MeshEditState?

    /// Why the last Tab press couldn't enter edit mode (`nil` after a
    /// successful toggle). Shown as an object-mode badge — a refused Tab must
    /// never be a silent no-op.
    public var meshEditRefusal: String?

    /// Live lattice (FFD) deform state; `nil` when not in lattice mode
    /// (specs/mesh-editing.md §Lattice deformer). Managed by
    /// `EditorDocument+Lattice.swift`.
    public var latticeEdit: LatticeEditState?

    /// Why the last lattice-mode entry was refused (`nil` after success);
    /// surfaced as a badge so a refusal is never a silent no-op.
    public var latticeRefusal: String?

    /// The mesh prim most recently committed by an edit session — after
    /// commit, the stage (not the file) is the viewport's source of truth for
    /// this prim's geometry, including across undo/redo.
    public var lastMeshEditPath: PrimPath?

    /// Bumped on every stack change so the menu can observe undo/redo enablement.
    public private(set) var revision: Int = 0

    /// Bumped only when an edit can change prim *geometry or topology* (points,
    /// face topology, prim add/remove), never for a transform-only edit. The
    /// viewport's expensive per-prim mesh extraction is memoized against this so
    /// an interactive translate/rotate/scale drag — which republishes the
    /// snapshot every pointer event — reuses the geometry it already built
    /// instead of re-walking every mesh's points on each event. Not
    /// observation-tracked: it is only read inside `computeViewportScene`, which
    /// is already gated on `viewportSceneRevision`.
    @ObservationIgnored public private(set) var geometryRevision: Int = 0

    /// Absolute path strings of every prim on the stage, for the viewport's
    /// live-stage sync (deleted prims get their entities disabled). Cached per
    /// revision so repeated SwiftUI reads don't re-walk a large stage.
    public var scenePrimPaths: Set<String> {
        let rev = revision // read tracked property so observers refresh
        if pathsCacheRevision != rev {
            pathsCache = Set(snapshot.allPrims().map(\.path.description))
            pathsCacheRevision = rev
        }
        return pathsCache
    }
    @ObservationIgnored private var pathsCacheRevision: Int = -1
    @ObservationIgnored private var pathsCache: Set<String> = []

    /// Cache backing `viewportScene` (see EditorDocument+ViewportScene),
    /// keyed by the viewport scene revision it was computed at.
    @ObservationIgnored var sceneCacheRevision: Int = -1
    @ObservationIgnored var sceneCache: ViewportScene = ViewportScene()

    /// Memoized per-prim renderable geometry, keyed by prim path and generation-
    /// stamped with `geometryRevision`. `computeViewportScene` still runs on
    /// every scene revision (transforms and visibility are cheap to reassemble),
    /// but the O(vertices) extraction in `Self.mesh(from:)` is skipped whenever
    /// geometry hasn't changed since the array was last built — the win that
    /// makes a transform drag stop re-meshing the whole stage each pointer event.
    /// Values are `Optional` so a prim that legitimately has no geometry (an
    /// Xform, or a malformed mesh) is cached as a hit, not re-extracted.
    @ObservationIgnored var meshCacheGeneration: Int = -1
    @ObservationIgnored var meshCache: [String: ViewportMeshData?] = [:]

    /// Cache backing `viewportMaterialOverrides` (see EditorDocument+ViewportMaterial),
    /// keyed by the revision it was computed at.
    @ObservationIgnored var materialOverrideCacheRevision: Int = -1
    @ObservationIgnored var materialOverrideCache: [String: ViewportKit.MaterialOverride] = [:]

    private let stage: InMemoryStage
    private let stack: CommandStack

    /// Opens a document over `snapshot`. Pass a `journal` to enable the crash-safe
    /// write-ahead log that also powers cross-launch session restore
    /// (specs/session-restoration.md); the `CommandStack` writes a checkpoint for
    /// `modelURL` immediately so recovery knows which file to replay against.
    public convenience init(
        snapshot: StageSnapshot = StageSnapshot(),
        modelURL: URL? = nil,
        journal: (any CommandJournal)? = nil
    ) {
        self.init(baseline: snapshot, modelURL: modelURL) { stage in
            CommandStack(stage: stage, journal: journal)
        }
    }

    /// Shared setup: seeds the stage/baseline from `baseline`, builds the command
    /// stack via `makeStack` (a fresh journaled stack, or a recovered one that
    /// replays a WAL), and wires the refresh hook. `rethrows` so the recovery
    /// path can surface a replay failure while the common path stays non-throwing.
    private init(
        baseline: StageSnapshot,
        modelURL: URL?,
        makeStack: (InMemoryStage) throws -> CommandStack
    ) rethrows {
        self.modelURL = modelURL
        self.snapshot = baseline
        self.baselineSnapshot = baseline
        let stage = InMemoryStage(baseline)
        self.stage = stage
        self.stack = try makeStack(stage)
        self.stack.onChange = { [weak self] in
            // Runs synchronously on the calling (main) thread — mirrors the
            // UndoManagerBridge's own assumeIsolated pattern.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Rebuilds a document by replaying a write-ahead log against the last-saved
    /// `baseline`, restoring the exact undo/redo stacks and the edited stage
    /// content (specs/session-restoration.md). `records` are the post-checkpoint
    /// WAL tail (see `SessionKit.RecoveryPlan`); `journal` is the same log so
    /// further edits keep appending. Throws only if replay itself fails, letting
    /// the caller fall back to a clean open.
    public static func restored(
        baseline: StageSnapshot,
        modelURL: URL?,
        journal: (any CommandJournal)?,
        records: [JournalRecord]
    ) throws -> EditorDocument {
        let document = try EditorDocument(baseline: baseline, modelURL: modelURL) { stage in
            try CommandStack.recovered(stage: stage, journal: journal, records: records)
        }
        document.reconcileAfterRecovery()
        return document
    }

    /// After a WAL replay the stage may differ from the last-saved baseline
    /// (unsaved edits). Republish the live snapshot and mark the document dirty
    /// iff it actually diverged, so the title bar's "Edited" state and the
    /// restore prompt's unsaved-edit indication are correct. `savedRevision`
    /// stays 0 (the baseline is the on-disk state), so `hasUnsavedChanges`
    /// reduces to "did replay change anything".
    private func reconcileAfterRecovery() {
        snapshot = stage.currentSnapshot
        geometryRevision &+= 1
        if snapshot != baselineSnapshot {
            revision &+= 1
        }
    }

    /// Restores isolate mode to `roots` (view-only; non-dirtying) — used when
    /// reapplying a restored session's view state.
    public func restoreIsolation(_ roots: some Sequence<PrimPath>) {
        setIsolation(IsolationState(roots: Set(roots)))
    }

    // MARK: Undo/redo surface

    public var canUndo: Bool { stack.canUndo }
    public var canRedo: Bool { stack.canRedo }
    public var undoLabel: String? { stack.undoLabel }
    public var redoLabel: String? { stack.redoLabel }

    /// Session breadcrumb trail (specs/diagnostics-logging.md). Property-
    /// injected by the composition root after creation (documents are built in
    /// several places — open, scratch, restore — and crumbs are diagnostics,
    /// not construction-critical). `nil` (tests, previews) is silent.
    /// `@ObservationIgnored`: never drives view updates.
    @ObservationIgnored public var breadcrumbs: (any BreadcrumbLogging)?

    public func undo() {
        breadcrumbs?.log(.command, level: .info, "undo",
                         metadata: ["label": undoLabel ?? ""])
        _ = try? stack.undo()
    }
    public func redo() {
        breadcrumbs?.log(.command, level: .info, "redo",
                         metadata: ["label": redoLabel ?? ""])
        _ = try? stack.redo()
    }

    /// Runs a command, surfacing (but not throwing) mutation errors so a bad
    /// edit from the UI never crashes the app. Returns the applied label.
    @discardableResult
    public func run(_ command: any EditCommand) -> String? {
        do {
            let label = try stack.run(command)
            breadcrumbs?.log(.command, level: .info, "run", metadata: ["label": label])
            return label
        } catch {
            // A failed mutation is exactly the kind of trouble a crash log
            // should retain — .error also forces an immediate flush.
            breadcrumbs?.log(.command, level: .error, "command failed",
                             metadata: ["error": "\(error)"])
            lastError = "\(error)"
            return nil
        }
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

    // MARK: Part-level editing (ROADMAP Milestone 3)

    /// Isolate-mode session overlay. **View-only**: it never authors to the
    /// stage, so entering/exiting isolate leaves `hasUnsavedChanges` untouched
    /// (specs/editing-model.md mutation rule 1). The viewport consults
    /// `viewportLivePrimPaths` to draw only the isolated lineage.
    public private(set) var isolation = IsolationState()

    /// The breadcrumb trail for the primary selection (empty with no selection).
    /// Drives the viewport breadcrumb bar and shows exactly where a drill-down
    /// landed in the hierarchy.
    public var breadcrumb: [PartSelection.Crumb] {
        guard let path = selection.primary else { return [] }
        return PartSelection.breadcrumb(to: path, in: snapshot)
    }

    /// Handles a viewport click that resolved to the deepest pickable prim
    /// `leaf`, applying the drill-down idiom: first click selects the whole
    /// top-level object, repeat clicks drill one level deeper toward `leaf`.
    public func drillInto(_ leaf: PrimPath) {
        guard let next = PartSelection.drillDown(picked: leaf, from: selection.primary) else { return }
        selection = Selection([next])
    }

    /// Walks the selection up one level toward the scene root. No-op at a
    /// top-level prim. Bound to the breadcrumb "up" affordance and ⌘↑.
    public func walkUpSelection() {
        guard let path = selection.primary, let up = PartSelection.walkUp(from: path) else { return }
        selection = Selection([up])
    }

    /// The Hide · Disable · Delete controls for `path`, pre-resolved to their
    /// current state (Hide↔Show, Disable↔Enable) for a context menu / inspector.
    public func partEditControls(for path: PrimPath) -> [PartEditControl] {
        guard let prim = snapshot.prim(at: path) else { return [] }
        return PartEditKind.controls(for: prim)
    }

    /// Applies a Hide / Disable / Delete action to `path` as one undoable edit,
    /// following the selection appropriately (delete clears it).
    public func performPartEdit(_ kind: PartEditKind, on path: PrimPath) {
        guard let command = PartEditCommandFactory.command(kind, for: path, in: snapshot),
              run(command) != nil else { return }
        if kind == .delete, selection.contains(path) { selection = .empty }
    }

    /// Isolate the current selection (or clear isolation when nothing is
    /// selected). View-only; bumps the revision so the viewport re-prunes.
    public func isolateSelection() {
        setIsolation(isolation.isolating(selection.paths))
    }

    /// Exit isolate mode.
    public func exitIsolation() { setIsolation(isolation.cleared()) }

    /// Toggle isolate mode on the current selection.
    public func toggleIsolation() {
        isolation.isActive ? exitIsolation() : isolateSelection()
    }

    /// View-only revision counter — bumped by isolate and other non-authoring
    /// view changes. Kept **separate** from `revision` so it never touches
    /// `hasUnsavedChanges`; folded into the viewport's scene revision so the
    /// viewport still re-prunes.
    public private(set) var viewRevision: Int = 0

    private func setIsolation(_ new: IsolationState) {
        guard new != isolation else { return }
        isolation = new
        viewRevision &+= 1   // re-prune the viewport without dirtying the document
    }

    /// The revision the viewport prunes against — combines authored edits and
    /// view-only changes (isolate) so both trigger a re-sync.
    public var viewportSceneRevision: Int { revision &+ viewRevision }

    /// The prim paths the viewport should draw: the live stage set minus any
    /// prims isolate mode hides. When isolation is inactive this equals
    /// `scenePrimPaths`. Because the hidden prims are merely dropped from the
    /// live set (the same seam structural deletes use), no stage opinion is
    /// authored — isolate stays non-dirtying.
    public var viewportLivePrimPaths: Set<String> {
        guard isolation.isActive else { return scenePrimPaths }
        let hidden = Set(isolation.hiddenPaths(in: snapshot).map(\.description))
        return scenePrimPaths.subtracting(hidden)
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

    // MARK: Translate gizmo (object-mode move arrows in the viewport)

    /// The viewport move gizmo: shown at the primary selection's world-space
    /// pivot in object mode; hidden in mesh edit mode or with nothing selected.
    /// The revision bump keeps it following the object during its own drag.
    public var translateGizmo: TranslateGizmoDescriptor? {
        guard gizmoMode == .translate, meshEdit == nil, let path = selection.primary,
              snapshot.prim(at: path) != nil else { return nil }
        let m = snapshot.worldMatrix(at: path)
        return TranslateGizmoDescriptor(origin: SIMD3(m[12], m[13], m[14]),
                                        revision: revision)
    }

    /// One live drag session per selected prim (multi-select moves together).
    @ObservationIgnored private var gizmoDragSessions: [TransformDragSession] = []

    /// Routes gizmo drag phases from the viewport: live-preview translations
    /// during the drag, then one coalesced undoable "Move" on release.
    public func handleTranslateGizmoDrag(_ phase: TranslateGizmoDragPhase) {
        switch phase {
        case .began:
            gizmoDragSessions = selection.paths
                .filter { snapshot.prim(at: $0) != nil }
                .map { makeDragSession(for: $0) }
        case let .changed(axis, distance):
            let worldDelta = axis.direction * distance
            for session in gizmoDragSessions {
                let delta = Self.worldDeltaToParentSpace(worldDelta, path: session.path,
                                                         in: snapshot)
                try? session.translate(by: [delta.x, delta.y, delta.z])
            }
            // Transform-only preview: geometry is untouched, so keep the
            // viewport's mesh cache warm across the drag.
            refresh(geometryChanged: false)
        case .ended:
            let commands = gizmoDragSessions.compactMap { $0.makeCommand(verb: "Move") }
            gizmoDragSessions = []
            switch commands.count {
            case 0: break
            case 1: run(commands[0])
            default:
                run(CompositeCommand(label: "Move \(commands.count) prims",
                                     commands: commands))
            }
        }
    }

    /// The move gizmo's world-space pivot, or `nil` when hidden — a
    /// string/array surface for tooling (harness, scripting) that can't
    /// import ViewportKit's descriptor types directly.
    public var translateGizmoOrigin: [Double]? {
        translateGizmo.map { [$0.origin.x, $0.origin.y, $0.origin.z] }
    }

    /// A complete began→changed→ended gizmo drag along a named world axis
    /// ("x" | "y" | "z") — the tooling counterpart of an arrow drag. Returns
    /// `false` (and does nothing) when the gizmo is hidden or the axis name
    /// is unknown.
    @discardableResult
    public func performTranslateGizmoDrag(axis name: String, distance: Double) -> Bool {
        guard translateGizmo != nil,
              let axis = ["x": GizmoAxis.x, "y": .y, "z": .z][name.lowercased()] else { return false }
        handleTranslateGizmoDrag(.began(axis))
        handleTranslateGizmoDrag(.changed(axis, distance))
        handleTranslateGizmoDrag(.ended)
        return true
    }

    /// A world-space translation delta expressed in `path`'s parent space —
    /// what a local-transform translation must change by to move the prim by
    /// `delta` in world space. Row-vector convention (`v' = v·M⁻¹`, direction
    /// only, using the parent's world matrix); identity parents short-circuit.
    static func worldDeltaToParentSpace(_ delta: SIMD3<Double>, path: PrimPath,
                                        in snapshot: StageSnapshot) -> SIMD3<Double> {
        let parent = path.parent
        guard !parent.isRoot else { return delta }
        let m = snapshot.worldMatrix(at: parent)
        guard let inv = Matrix4.inverse(m) else { return delta }
        return SIMD3(
            delta.x * inv[0] + delta.y * inv[4] + delta.z * inv[8],
            delta.x * inv[1] + delta.y * inv[5] + delta.z * inv[9],
            delta.x * inv[2] + delta.y * inv[6] + delta.z * inv[10])
    }

    // MARK: Rotate / scale gizmos (shared infrastructure)

    /// The selection's world-space gizmo pivot (median centroid of the selected
    /// prims' world origins, or the primary prim's origin for `individual`),
    /// or `nil` when nothing eligible is selected.
    private var gizmoPivot: SIMD3<Double>? {
        let paths = selection.paths.filter { snapshot.prim(at: $0) != nil }
        guard !paths.isEmpty else { return nil }
        func origin(_ p: PrimPath) -> SIMD3<Double> {
            let m = snapshot.worldMatrix(at: p); return SIMD3(m[12], m[13], m[14])
        }
        switch gizmoPivotMode {
        case .individual:
            guard let primary = selection.primary else { return origin(paths[0]) }
            return origin(primary)
        case .median:
            let sum = paths.reduce(SIMD3<Double>.zero) { $0 + origin($1) }
            return sum / Double(paths.count)
        }
    }

    /// The gizmo's basis for the current orientation: `world`, or the primary
    /// selection's world rotation basis for `local` (the normalized rows of its
    /// world matrix, row-vector convention).
    private var gizmoBasis: GizmoBasis {
        guard gizmoOrientation == .local, let path = selection.primary,
              snapshot.prim(at: path) != nil else { return .world }
        let m = snapshot.worldMatrix(at: path)
        func row(_ r: Int) -> SIMD3<Double> {
            Self.normalize(SIMD3(m[r * 4], m[r * 4 + 1], m[r * 4 + 2]))
        }
        return GizmoBasis(x: row(0), y: row(1), z: row(2))
    }

    /// The rotate gizmo, shown at the selection pivot in rotate mode.
    public var rotateGizmo: RotateGizmoDescriptor? {
        guard gizmoMode == .rotate, meshEdit == nil, let pivot = gizmoPivot else { return nil }
        return RotateGizmoDescriptor(origin: pivot, basis: gizmoBasis, revision: revision)
    }

    /// The scale gizmo, shown at the selection pivot in scale mode.
    public var scaleGizmo: ScaleGizmoDescriptor? {
        guard gizmoMode == .scale, meshEdit == nil, let pivot = gizmoPivot else { return nil }
        return ScaleGizmoDescriptor(origin: pivot, basis: gizmoBasis, revision: revision)
    }

    /// A rotate/scale drag in flight: the per-prim session plus the world and
    /// parent-world matrices captured at grab time (the op composes from the
    /// pre-drag pose, so repeated live frames don't accumulate).
    private struct GizmoTransformDrag {
        let session: TransformDragSession
        let startWorld: [Double]
        let startParentWorld: [Double]
    }
    @ObservationIgnored private var gizmoTransformDrags: [GizmoTransformDrag] = []
    @ObservationIgnored private var gizmoDragPivot: SIMD3<Double> = .zero
    @ObservationIgnored private var gizmoDragBasis: GizmoBasis = .world

    private func beginGizmoTransformDrag() {
        gizmoDragPivot = gizmoPivot ?? .zero
        gizmoDragBasis = gizmoBasis
        gizmoTransformDrags = selection.paths
            .filter { snapshot.prim(at: $0) != nil }
            .map { path in
                let parent = path.parent
                return GizmoTransformDrag(
                    session: makeDragSession(for: path),
                    startWorld: snapshot.worldMatrix(at: path),
                    startParentWorld: parent.isRoot ? Matrix4.identity
                        : snapshot.worldMatrix(at: parent))
            }
    }

    private func endGizmoTransformDrag(verb: String) {
        let commands = gizmoTransformDrags.compactMap { $0.session.makeCommand(verb: verb) }
        gizmoTransformDrags = []
        switch commands.count {
        case 0: break
        case 1: run(commands[0])
        default: run(CompositeCommand(label: "\(verb) \(commands.count) prims", commands: commands))
        }
    }

    /// Composes a world-space op about the drag pivot into each dragged prim's
    /// pre-drag world pose, converts back to parent-local, and previews it.
    /// `world' = startWorld · T(-pivot) · op · T(pivot)`; `local' = world' ·
    /// startParentWorld⁻¹` (row-vector convention).
    private func applyWorldOp(_ op: [Double]) {
        let mid = Matrix4.multiply(
            Matrix4.multiply(Self.translationMatrix(-gizmoDragPivot), op),
            Self.translationMatrix(gizmoDragPivot))
        for drag in gizmoTransformDrags {
            let worldPrime = Matrix4.multiply(drag.startWorld, mid)
            let local = Matrix4.inverse(drag.startParentWorld)
                .map { Matrix4.multiply(worldPrime, $0) } ?? worldPrime
            try? drag.session.update(TRS.from(matrix: local))
        }
        // World-space rotate/uniform-scale preview: transform-only.
        refresh(geometryChanged: false)
    }

    /// Routes rotate-gizmo drag phases: live world-space rotation about the
    /// pivot during the drag, then one coalesced undoable "Rotate" on release.
    public func handleRotateGizmoDrag(_ phase: RotateGizmoDragPhase) {
        switch phase {
        case .began:
            beginGizmoTransformDrag()
        case let .changed(axis, degrees):
            let snapped = Self.snapValue(degrees, to: snap.rotationDegrees)
            let dir = gizmoDragBasis.direction(axis)
            applyWorldOp(Self.axisRotationMatrix(axis: dir, degrees: snapped))
        case .ended:
            endGizmoTransformDrag(verb: "Rotate")
        }
    }

    /// Routes scale-gizmo drag phases: a uniform handle scales about the pivot
    /// in world space; a per-axis handle scales that axis in each prim's own
    /// local frame (shear-free). Coalesces into one undoable "Scale".
    public func handleScaleGizmoDrag(_ phase: ScaleGizmoDragPhase) {
        switch phase {
        case .began:
            beginGizmoTransformDrag()
        case let .changed(handle, factor):
            switch handle {
            case .uniform:
                let f = Self.snapFactor(factor, step: snap.scale)
                applyWorldOp(Self.diagonalScaleMatrix([f, f, f]))
            case let .axis(axis):
                for drag in gizmoTransformDrags {
                    var factors = [1.0, 1.0, 1.0]
                    factors[axis.rawValue] = factor
                    try? drag.session.scale(byPerAxis: factors)
                }
                // Per-axis local scale preview: transform-only.
                refresh(geometryChanged: false)
            }
        case .ended:
            endGizmoTransformDrag(verb: "Scale")
        }
    }

    /// The rotate gizmo's world pivot, or `nil` when hidden — string/array
    /// surface for tooling that can't import ViewportKit's descriptor types.
    public var rotateGizmoOrigin: [Double]? {
        rotateGizmo.map { [$0.origin.x, $0.origin.y, $0.origin.z] }
    }

    /// The scale gizmo's world pivot, or `nil` when hidden.
    public var scaleGizmoOrigin: [Double]? {
        scaleGizmo.map { [$0.origin.x, $0.origin.y, $0.origin.z] }
    }

    /// A complete began→changed→ended rotate-gizmo drag about a named axis
    /// ("x" | "y" | "z") by `degrees` — the tooling counterpart of a ring drag.
    /// Returns `false` (no-op) when the gizmo is hidden or the axis is unknown.
    @discardableResult
    public func performRotateGizmoDrag(axis name: String, degrees: Double) -> Bool {
        guard rotateGizmo != nil, let axis = Self.namedAxis(name) else { return false }
        handleRotateGizmoDrag(.began(axis))
        handleRotateGizmoDrag(.changed(axis, degrees))
        handleRotateGizmoDrag(.ended)
        return true
    }

    /// A complete began→changed→ended scale-gizmo drag on a named handle
    /// ("uniform" | "x" | "y" | "z") by `factor`. Returns `false` (no-op) when
    /// the gizmo is hidden or the handle name is unknown.
    @discardableResult
    public func performScaleGizmoDrag(handle name: String, factor: Double) -> Bool {
        guard scaleGizmo != nil else { return false }
        let handle: ScaleHandle
        if name.lowercased() == "uniform" {
            handle = .uniform
        } else if let axis = Self.namedAxis(name) {
            handle = .axis(axis)
        } else {
            return false
        }
        handleScaleGizmoDrag(.began(handle))
        handleScaleGizmoDrag(.changed(handle, factor))
        handleScaleGizmoDrag(.ended)
        return true
    }

    // MARK: Modal transform (Blender-style G/R/S)

    /// The live modal transform session (grab/rotate/scale), or `nil` when none
    /// is active. The viewport reads `hudText` from it and drives its
    /// constraint/numeric inputs through the `modal*` methods below; the actual
    /// mutation reuses the same coalesced-undo path as the handle gizmos.
    public private(set) var modalTransform: ModalTransform?

    /// Starts a modal transform of `kind`, seeded from the selection's pivot and
    /// basis. No-op (and returns `false`) when nothing eligible is selected or a
    /// modal session is already in flight. On success the same per-prim drag
    /// sessions the handle gizmos use are opened, so confirm coalesces to one
    /// undoable command and cancel restores the pre-transform pose exactly.
    @discardableResult
    public func beginModalTransform(kind: ModalTransformKind) -> Bool {
        guard modalTransform == nil, meshEdit == nil, let pivot = gizmoPivot else { return false }
        modalTransform = ModalTransform(kind: kind, pivot: pivot, basis: gizmoBasis)
        beginGizmoTransformDrag()
        return true
    }

    /// Previews a proposed op (from `ModalTransform.proposedOp`) live, exactly
    /// like a handle drag frame. No-op when no modal session is active.
    public func updateModalTransform(_ op: ModalOp) {
        guard modalTransform != nil else { return }
        applyWorldOp(Self.matrix(for: op))
    }

    /// Sets the axis/plane constraint on the active modal session (X/Y/Z, Shift
    /// for a plane, a repeat toggles local). The caller re-previews from the
    /// latest pointer afterwards.
    public func modalSetConstraint(axis: GizmoAxis, shift: Bool) {
        modalTransform?.setConstraint(axis: axis, shift: shift)
    }

    public func modalTypeDigit(_ c: Character) { modalTransform?.typeDigit(c) }
    public func modalBackspaceNumeric() { modalTransform?.backspaceNumeric() }

    /// Confirms the modal transform: emits exactly one coalesced undoable
    /// command ("Move"/"Rotate"/"Scale") for the whole gesture.
    public func confirmModalTransform() {
        guard let modal = modalTransform else { return }
        modalTransform = nil
        endGizmoTransformDrag(verb: modal.kind.undoVerb)
    }

    /// Cancels the modal transform: restores every dragged prim to its
    /// pre-transform pose and emits nothing (the stage ends byte-identical).
    public func cancelModalTransform() {
        guard modalTransform != nil else { return }
        modalTransform = nil
        for drag in gizmoTransformDrags { try? drag.session.cancel() }
        gizmoTransformDrags = []
        refresh(geometryChanged: false)
    }

    /// The world-space op matrix for a proposed `ModalOp`, applied about the
    /// pivot by `applyWorldOp` (which cancels the pivot for a pure translation).
    static func matrix(for op: ModalOp) -> [Double] {
        switch op {
        case let .translate(delta):
            translationMatrix(delta)
        case let .rotate(axis, degrees):
            axisRotationMatrix(axis: axis, degrees: degrees)
        case let .scale(basis, factors):
            basisScaleMatrix(basis: basis, factors: [factors.x, factors.y, factors.z])
        }
    }

    /// A row-vector world matrix that scales by `factors` along `basis`'s axes:
    /// `L = Bᵀ · diag(f) · B`, where `B`'s rows are the (orthonormal) basis
    /// axes. Reduces to a plain diagonal scale for the world basis.
    static func basisScaleMatrix(basis: GizmoBasis, factors: [Double]) -> [Double] {
        let b: [Double] = [
            basis.x.x, basis.x.y, basis.x.z, 0,
            basis.y.x, basis.y.y, basis.y.z, 0,
            basis.z.x, basis.z.y, basis.z.z, 0,
            0, 0, 0, 1,
        ]
        var bt = [Double](repeating: 0, count: 16)
        for r in 0..<4 { for c in 0..<4 { bt[r * 4 + c] = b[c * 4 + r] } }
        return Matrix4.multiply(Matrix4.multiply(bt, diagonalScaleMatrix(factors)), b)
    }

    // MARK: Gizmo math helpers (pure)

    private static func namedAxis(_ name: String) -> GizmoAxis? {
        ["x": GizmoAxis.x, "y": .y, "z": .z][name.lowercased()]
    }

    private static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return l > 1e-12 ? v / l : v
    }

    static func snapValue(_ value: Double, to step: Double?) -> Double {
        guard let step, step > 0 else { return value }
        return (value / step).rounded() * step
    }

    /// Snaps a multiplicative scale factor by snapping the *resulting* unit
    /// (`1 + delta`) to the step, so a 0.25 step lands on ×0.75, ×1.0, ×1.25…
    static func snapFactor(_ factor: Double, step: Double?) -> Double {
        guard let step, step > 0 else { return factor }
        return snapValue(factor, to: step)
    }

    /// A row-major translation matrix (row-vector convention).
    static func translationMatrix(_ t: SIMD3<Double>) -> [Double] {
        var m = Matrix4.identity; m[12] = t.x; m[13] = t.y; m[14] = t.z; return m
    }

    /// A row-major diagonal scale matrix.
    static func diagonalScaleMatrix(_ s: [Double]) -> [Double] {
        [s[0], 0, 0, 0, 0, s[1], 0, 0, 0, 0, s[2], 0, 0, 0, 0, 1]
    }

    /// Row-vector rotation matrix about an arbitrary world axis by `degrees`
    /// (right-hand rule) — the transpose of the column-vector Rodrigues form,
    /// matching `Matrix4.rotationX/Y/Z`.
    static func axisRotationMatrix(axis k: SIMD3<Double>, degrees: Double) -> [Double] {
        let n = normalize(k)
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r), t = 1 - c
        let x = n.x, y = n.y, z = n.z
        return [
            t * x * x + c,     t * x * y + s * z, t * x * z - s * y, 0,
            t * x * y - s * z, t * y * y + c,     t * y * z + s * x, 0,
            t * x * z + s * y, t * y * z - s * x, t * z * z + c,     0,
            0, 0, 0, 1,
        ]
    }

    /// Per-prim local transforms for the viewport (column-major, RealityKit
    /// convention), so transform edits — gizmo drags, inspector fields, undo —
    /// render live without a file reload. Only prims authoring an
    /// `xformOp:transform` are included. Cached per revision.
    public var viewportLiveTransforms: [String: float4x4] {
        let rev = revision // read tracked property so observers refresh
        if transformCacheRevision != rev {
            var out: [String: float4x4] = [:]
            for prim in snapshot.allPrims() {
                guard let attr = prim.attribute(named: transformAttributeName),
                      case let .matrix4(m) = attr.value, m.count == 16 else { continue }
                // USD row-major/row-vector → simd column-major/column-vector:
                // each USD row becomes a simd column (the transpose identity).
                out[prim.path.description] = float4x4(
                    SIMD4(Float(m[0]), Float(m[1]), Float(m[2]), Float(m[3])),
                    SIMD4(Float(m[4]), Float(m[5]), Float(m[6]), Float(m[7])),
                    SIMD4(Float(m[8]), Float(m[9]), Float(m[10]), Float(m[11])),
                    SIMD4(Float(m[12]), Float(m[13]), Float(m[14]), Float(m[15])))
            }
            transformCache = out
            transformCacheRevision = rev
        }
        return transformCache
    }
    @ObservationIgnored private var transformCacheRevision: Int = -1
    @ObservationIgnored private var transformCache: [String: float4x4] = [:]

    // MARK: Stage metadata edits

    public func setStageMetadata(_ metadata: StageMetadata) {
        guard metadata != snapshot.metadata else { return }
        run(SetStageMetadataCommand(newMetadata: metadata, oldMetadata: snapshot.metadata))
    }

    // MARK: Variant edits

    /// The variant sets authored on `path` (empty when the prim has none), for
    /// the inspector's variant picker.
    public func variantSets(at path: PrimPath) -> [VariantSet] {
        snapshot.prim(at: path)?.variantSets ?? []
    }

    /// Switches the active variant of a named set on `path` as one undoable
    /// command. No-op when the prim has no such set or the selection is
    /// unchanged.
    public func setVariantSelection(_ path: PrimPath, set setName: String, to selection: String?) {
        guard let prim = snapshot.prim(at: path),
              let variantSet = prim.variantSets.first(where: { $0.name == setName }),
              variantSet.selection != selection else { return }
        run(SetVariantSelectionCommand(
            path: path, setName: setName,
            newSelection: selection, oldSelection: variantSet.selection))
    }

    // MARK: Mechanism (rigid articulation) state switching

    /// Every rigid articulation (hinge/slider) authored on the open stage, in
    /// stable path order — the model behind the inspector's States panel. Pure
    /// read of the live snapshot; empty for assets with no mechanisms.
    public var articulations: [DiscoveredJoint] { JointDiscovery.joints(in: snapshot) }

    /// Every discrete variant set on the stage, paired with the prim it lives on,
    /// so the States panel can drive colorway/size/state switches stage-wide (the
    /// per-prim variant picker in the Prim tab stays scoped to the selection).
    public var stageVariantSets: [(path: PrimPath, set: VariantSet)] {
        snapshot.allPrims()
            .sorted { $0.path.description < $1.path.description }
            .flatMap { prim in prim.variantSets.map { (prim.path, $0) } }
    }

    /// Drive a joint to a named state ("open"/"closed"/…) as one undoable command,
    /// and select the pivot so the viewport gizmo/outliner follow. No-op when the
    /// pivot carries no joint or the state is undeclared.
    public func setJointState(_ pivotPath: PrimPath, state: String) {
        guard let command = SetJointStateCommand.make(pivotPath: pivotPath, state: state, in: snapshot)
        else { return }
        guard run(command) != nil else { return }
        selection = selection.selecting(pivotPath)
    }

    /// Drive a joint to an explicit in-limit value (degrees for a hinge, scene
    /// units for a slider) as one undoable command. No-op for an out-of-limit
    /// value or a pivot with no joint; the selection is left untouched so a live
    /// scrub doesn't thrash the outliner.
    public func setJointValue(_ pivotPath: PrimPath, value: Double) {
        guard let command = SetJointStateCommand.make(pivotPath: pivotPath, value: value, in: snapshot)
        else { return }
        run(command)
    }

    // MARK: Material edits

    /// The material bound to `path` and the prim its inputs live on — following
    /// the binding up the namespace, so selecting a deep child part shows the
    /// material it actually renders with. `nil` when nothing in the chain binds
    /// one.
    public func boundMaterial(for path: PrimPath) -> ResolvedMaterial? {
        MaterialBinding.resolve(for: path, in: snapshot)
    }

    /// The authored value of `input` on `material`'s surface, or `nil` when it
    /// carries no opinion (the inspector then shows `input.fallback`).
    public func materialInput(_ input: PreviewSurfaceInput, on material: ResolvedMaterial) -> AttributeValue? {
        snapshot.prim(at: material.surfacePath)?.attribute(named: input.attributeName)?.value
    }

    /// Sets a UsdPreviewSurface input on a material as one undoable command.
    /// No-op when the value is unchanged or illegal for the input's declared
    /// type. Returns `true` when an edit ran.
    @discardableResult
    public func setMaterialInput(
        _ input: PreviewSurfaceInput,
        on material: ResolvedMaterial,
        to value: AttributeValue
    ) -> Bool {
        guard let command = SetMaterialInputCommand.make(
            material, input: input, value: value, in: snapshot) else { return false }
        return run(command) != nil
    }

    /// Clears an authored input so the material falls back to the USD default,
    /// undoably. Returns `true` when the input was authored and got removed.
    @discardableResult
    public func clearMaterialInput(_ input: PreviewSurfaceInput, on material: ResolvedMaterial) -> Bool {
        guard let command = RemoveAttributeCommand.make(
            path: material.surfacePath, name: input.attributeName, in: snapshot) else { return false }
        return run(command) != nil
    }

    /// Every distinct material bound anywhere within the subtrees of `paths`,
    /// deduped by surface prim — the set a model-wide recolor should touch.
    ///
    /// Walks each root's whole subtree (not just the root prim) so a model whose
    /// parts each bind their own material yields all of them, and resolves
    /// bindings up the namespace so parts inheriting a shared material collapse
    /// to a single entry. Returned in first-seen depth-first order.
    public func materials(under paths: [PrimPath]) -> [ResolvedMaterial] {
        var seen = Set<PrimPath>()
        var result: [ResolvedMaterial] = []
        for root in paths {
            guard let rootPrim = snapshot.prim(at: root) else { continue }
            for prim in rootPrim.flattened() {
                guard let material = MaterialBinding.resolve(for: prim.path, in: snapshot) else { continue }
                if seen.insert(material.surfacePath).inserted { result.append(material) }
            }
        }
        return result
    }

    /// Every distinct material in the stage, resolved once — the scope the
    /// stage-wide recolor panel operates over. Walks from each top-level root so
    /// per-part materials all surface, de-duplicated by the resolver.
    public var allMaterials: [ResolvedMaterial] {
        let roots = snapshot.allPrims().filter { $0.path.depth == 1 }.map(\.path)
        return materials(under: roots)
    }

    /// The base albedo of a material: its authored `diffuseColor` when present,
    /// else the UsdPreviewSurface fallback. Used to seed recolor swatches.
    public func diffuseColor(of material: ResolvedMaterial) -> [Double] {
        let input = PreviewSurfaceInput.named("diffuseColor")!
        if case let .vector(v)? = materialInput(input, on: material), v.count == 3 {
            return v
        }
        return [0.18, 0.18, 0.18]
    }

    /// Recolors a single material's base albedo, undoably. Convenience over
    /// ``recolorMaterials(_:input:to:)`` for the per-material recolor panel rows.
    @discardableResult
    public func recolor(_ material: ResolvedMaterial, to rgb: [Double]) -> Bool {
        recolorMaterials([material], input: PreviewSurfaceInput.named("diffuseColor")!,
                         to: .vector(rgb))
    }

    /// Creates a new UsdPreviewSurface material and binds it to `path`, undoably.
    /// Because bindings inherit down namespace, binding on a model's root gives
    /// every part under it the material — the "this model has no material yet,
    /// give it one I can recolour" path. Returns `true` when the material was
    /// created.
    @discardableResult
    public func createAndBindMaterial(
        to path: PrimPath,
        baseColor: [Double] = [0.18, 0.18, 0.18]
    ) -> Bool {
        guard let command = CreateMaterialCommand.make(
            bindingTo: path, baseColor: baseColor, in: snapshot) else { return false }
        return run(command) != nil
    }

    /// Sets one UsdPreviewSurface input across several materials as a single
    /// undoable command — the model-wide recolor path. No-op materials (value
    /// already set, or illegal for the input) are dropped; when every material
    /// is a no-op nothing runs. Returns `true` when an edit ran.
    @discardableResult
    public func recolorMaterials(
        _ materials: [ResolvedMaterial],
        input: PreviewSurfaceInput,
        to value: AttributeValue
    ) -> Bool {
        let commands: [any EditCommand] = materials.compactMap {
            SetMaterialInputCommand.make($0, input: input, value: value, in: snapshot)
        }
        switch commands.count {
        case 0: return false
        case 1: return run(commands[0]) != nil
        default:
            return run(CompositeCommand(
                label: "Recolor \(commands.count) materials", commands: commands)) != nil
        }
    }

    // MARK: Scale / units

    /// Normalizes the stage's `metersPerUnit` to `target`, preserving real-world
    /// size by baking a compensating scale into each root prim — the toolbar/menu
    /// surface for `ScaleFixer`, as one undoable command. Returns `true` when a
    /// fix ran (a no-op when already normalized or `target` is invalid).
    @discardableResult
    public func fixScale(targetMetersPerUnit target: Double = 1.0) -> Bool {
        guard let command = ScaleFixer.command(for: stage, targetMetersPerUnit: target) else { return false }
        return run(command) != nil
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

    // MARK: Save

    /// The stack revision last flushed to disk; `revision != savedRevision`
    /// means unsaved changes ("Edited" in the title bar).
    public private(set) var savedRevision: Int = 0

    public var hasUnsavedChanges: Bool { revision != savedRevision }

    /// Writes the current stage to `url` (.usda/.usd pure Swift; .usdc/.usdz
    /// via the bridge). Throws `StageSaver.SaveError` / bridge errors — the
    /// caller surfaces them; a failed save never clobbers the existing file.
    public func save(to url: URL, executor: ProcessBridgeExecutor?) async throws {
        // Flush a live edit session first so what's on screen is what's saved.
        if meshEdit != nil { exitMeshEditMode(commit: true) }
        try await StageSaver.save(snapshot, to: url, executor: executor)
        savedRevision = revision
        // The freshly written state is the new diff baseline.
        baselineSnapshot = snapshot
        // Flatten the write-ahead log to a checkpoint at the just-saved file so
        // crash recovery / session restore replays against it with an empty tail
        // (the on-disk state is now the baseline; replaying the pre-save commands
        // onto it would double-apply them). In-session undo history is kept.
        stack.checkpointSaved(sourceURL: url)
    }

    // MARK: Console (REPL) edits

    /// Records the result of one interactive-console submission as a single
    /// undoable command (ROADMAP Milestone 5 — "single-undo script runs").
    ///
    /// `after` is the stage re-opened from the file the console ran against. A
    /// query-only submission (or one that never called `stage.Save()`) leaves the
    /// file unchanged, so `after` matches the live stage and nothing is pushed —
    /// the console stays undo-neutral until it actually authors an edit. Only the
    /// document content is compared (`sourceURL` differs because `after` came from
    /// a temp file, and is irrelevant to the applied command).
    @discardableResult
    public func applyConsoleEdit(after: StageSnapshot, label: String) -> Bool {
        let before = snapshot
        guard after.metadata != before.metadata || after.rootPrims != before.rootPrims else {
            return false
        }
        return run(ReplaceStageCommand(before: before, after: after, opLabel: label)) != nil
    }

    // MARK: Export compliance gating

    /// Runs `profile`'s compliance check over the live stage so the export UI can
    /// gate on it (ROADMAP Milestone 5 — "wire the export path through
    /// ComplianceChecker gating in the app UI"). Defaults to the ARKit profile,
    /// which blocks on errors.
    public func exportCompliance(profile: ValidationProfile = .arkit) -> ComplianceResult {
        ComplianceChecker(profile: profile).check(snapshot)
    }

    // MARK: Private

    /// Republishes the live stage snapshot and bumps the viewport's revision.
    ///
    /// `geometryChanged` defaults to `true` so every path is correct-by-default:
    /// a caller that forgets simply loses the fast path, never correctness. Only
    /// the transform-only gizmo drag handlers (translate/rotate/scale live
    /// previews, which author `xformOp:transform` and nothing else) pass `false`
    /// to keep the geometry cache warm across the drag.
    private func refresh(geometryChanged: Bool = true) {
        snapshot = stage.currentSnapshot
        revision &+= 1
        if geometryChanged { geometryRevision &+= 1 }
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
