import Foundation
import Observation
import simd
import USDCore
import USDBridge
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

    /// The active selection (multi-select; part-level semantics per PRD §5.3).
    public var selection: Selection = .empty

    /// Snapping shared by the numeric inspector fields and the viewport gizmo.
    public var snap: SnapSettings = .off

    /// Live mesh edit-mode state; `nil` in object mode (Phase 6,
    /// specs/mesh-editing.md). Managed by `EditorDocument+MeshEdit.swift`.
    public var meshEdit: MeshEditState?

    /// Why the last Tab press couldn't enter edit mode (`nil` after a
    /// successful toggle). Shown as an object-mode badge — a refused Tab must
    /// never be a silent no-op.
    public var meshEditRefusal: String?

    /// The mesh prim most recently committed by an edit session — after
    /// commit, the stage (not the file) is the viewport's source of truth for
    /// this prim's geometry, including across undo/redo.
    public var lastMeshEditPath: PrimPath?

    /// Bumped on every stack change so the menu can observe undo/redo enablement.
    public private(set) var revision: Int = 0

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

    /// Cache backing `viewportMaterialOverrides` (see EditorDocument+ViewportMaterial),
    /// keyed by the revision it was computed at.
    @ObservationIgnored var materialOverrideCacheRevision: Int = -1
    @ObservationIgnored var materialOverrideCache: [String: ViewportKit.MaterialOverride] = [:]

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

    // MARK: Translate gizmo (object-mode move arrows in the viewport)

    /// The viewport move gizmo: shown at the primary selection's world-space
    /// pivot in object mode; hidden in mesh edit mode or with nothing selected.
    /// The revision bump keeps it following the object during its own drag.
    public var translateGizmo: TranslateGizmoDescriptor? {
        guard meshEdit == nil, let path = selection.primary,
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
            refresh() // republish the snapshot so the viewport previews live
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
