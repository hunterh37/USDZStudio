# EditingKit Specification — Commands, Undo, Mutation Rules

## Philosophy

Every mutation of the stage flows through one narrow gate: `EditCommand`. This buys us undo/redo, scripting parity (scripts can emit the same commands), a change journal for debugging, and a future path to collaborative editing — all from one pattern.

## Command Protocol

```swift
public protocol EditCommand {
    var label: String { get }                       // "Move Cube", "Rename Prim"
    var coalescingKey: String? { get }              // continuous gestures merge
    func execute(on stage: USDStageMutable) async throws
    func undo(on stage: USDStageMutable) async throws
}
```

### v1 Command Catalog

| Command | Notes |
|---|---|
| `SetTransformCommand` | TRS on Xformable; gizmo drags coalesce by key `transform:<path>` |
| `SetAttributeCommand` | generic typed attribute set; captures prior value for undo (undo *removes* the attribute when it was previously unauthored) |
| `RemoveAttributeCommand` | un-authors an attribute so its schema fallback applies again; captures the removed attribute (qualifiers + time samples) for undo. Backs "revert to default" in the material inspector |
| `RenamePrimCommand` | validates USD name legality; updates selection |
| `ReparentPrimCommand` | preserves world transform option (recomputes local xform against new parent) |
| `SetTransformCommand` on child prims | works at any depth of the hierarchy; if the prim isn't Xformable (bare Mesh), an Xform op is authored on it directly — moving a wheel inside a car "just works" |
| `DuplicatePrimCommand` / `DeletePrimCommand` | delete = deactivate + tombstone for undo (true removal on save) |
| `SetVisibilityCommand` | Hide/show part: authors `visibility = invisible` — part remains in the exported file and is toggleable at runtime in RealityKit |
| `SetActiveCommand` | Disable part: `active = false` — prim excluded from composition and from export (distinct from Hide; UI copy makes the difference explicit) |
| `CreatePrimCommand` | Xform/Scope/Material creation |
| `SetMaterialBindingCommand` | mesh ↔ material |
| `SetMaterialInputCommand` | PreviewSurface param, gated on the `PreviewSurfaceInput` catalog (mutation rule 0 — the catalog *is* the RealityKit-supported subset). Values are clamped into the input's declared range, then rejected if they still don't match its type. Targets the `ResolvedMaterial.surfacePath`, never a raw path (see Material Resolution). Texture path swap awaits `UsdUVTexture` authoring |
| `SetVariantSelectionCommand` | variant switching (undoable) |
| `SetStageMetadataCommand` | upAxis, metersPerUnit, defaultPrim… |
| `ScaleFixCommand` | composite: computes uniform scale to target size |
| `CompositeCommand` | ordered children, single undo entry (used by scripts & quick-fixes) |

## Material Resolution

Material editing never takes a raw prim path. `MaterialBinding.resolve(for:in:)`
returns a `ResolvedMaterial` — the bound `Material` prim (the user-facing
identity, used for undo labels) plus the `surfacePath` its `inputs:*` actually
live on — and the commands take that. Three shapes have to agree:

1. **Binding spelling.** The bridge surfaces a real `material:binding`
   relationship; `USDAuthorStage` records a bare sanitized name in prim
   metadata. Both resolve.
2. **Inheritance.** UsdShade bindings inherit down namespace, so resolution
   walks ancestors — selecting `/Car/Body/Trim` edits the material it renders
   with, and the closest binding wins. A prim inside a `Material` (i.e. its
   shader) resolves to that material rather than dead-ending.
3. **Where inputs live.** Real files author a `Shader` child
   (`info:id = "UsdPreviewSurface"`) that carries the inputs, with the Material
   only routing it via `outputs:surface`; our own importer flattens the inputs
   onto the Material prim. `surfacePath` picks the preview-surface shader when
   there is one and the Material otherwise. **This distinction is load-bearing:
   authoring `inputs:*` onto the Material prim when a shader owns them is
   silently inert — RealityKit renders the shader's opinion.**

`outputs:surface` connections aren't modelled in the snapshot yet, so a material
with several preview surfaces resolves to the first in depth-first order.
Modelling connections is the fix when a file in the wild needs it.

## Undo Integration

- Custom `EditHistory` stack (not raw NSUndoManager semantics) bridged **to** `NSUndoManager` so native menu items/⌘Z work and document dirty-state stays correct.
- Coalescing: commands with equal `coalescingKey` within one gesture merge (first `undo` state kept, last `execute` state kept).
- History panel (stretch): list of applied commands, click to jump.

## Mutation Rules

0. **Author only what RealityKit renders.** Every command in the catalog creates/edits constructs in RealityKit's supported subset of USD (PreviewSurface materials, standard Xform/Mesh/SkelRoot schemas, PNG/JPEG textures). There is deliberately no command for authoring MaterialX, custom schemas, or exotic composition. Pre-existing unsupported data in opened files is preserved untouched (never silently stripped) unless the user explicitly runs a "Strip non-RealityKit data" cleanup action or export option.

1. All edits authored to the **root layer** by default (session layer reserved for view-only state like isolate/visibility-preview).
2. Sparse overrides preferred — editing a referenced prim writes `over`, never inlines the reference.
3. Commands run on `StageActor`; UI receives resulting `StageChange` events and updates optimistically only for scrub gestures (numeric field drag shows live value; command commits on release).
4. A command that throws mid-composite triggers rollback of already-executed children.

## Dirty State & Saving

- Document dirty iff history has entries past the save-mark (or stage metadata changed).
- Save paths: overwrite `.usdz` (repackage), Save As `.usda/.usdc/.usdz`, Export Flattened. Tombstoned (deleted) prims are physically removed at save time.
- Crash safety: a **write-ahead log of serialized commands** since the last save, written under Application Support; replay is offered on relaunch after a crash. Implemented in EditingKit (Milestone 4):

  - `CommandStack` wraps the document stage in a `JournalingStage` proxy. While a command executes, every `StageMutation` it applies is captured together with the mutation that reverses it — computed from the stage state immediately *before* the apply (`StageMutation.inverse(reading:)`). One `JournalRecord.command(label:forward:inverse:)` is appended per committed command; `undo()`/`redo()` append `.undo`/`.redo` markers. This generalizes the mesh-edit session journal: no command needs per-command journaling code, because everything funnels through `stage.apply`.
  - `FileCommandJournal` is the WAL: JSON Lines, one record per line, `fsync`ed on append, so a record that `append` has returned from survives `SIGKILL` or power loss. A trailing line torn by a crash is discarded on read; complete records before it are unaffected.
  - `SessionStore` owns the on-disk layout (`<root>/<sessionID>/journal.wal` + a `session.live` sentinel). The sentinel is written on open and the directory removed on a clean close, so any session still carrying a sentinel on relaunch is one a killed process left behind. `recoverableSessions()` turns each into a `RecoveryPlan` — the document from the WAL's last checkpoint plus the records after it.
  - `CommandStack.recovered(stage:journal:records:)` replays a plan against the freshly reopened document, restoring stage content **and** both the undo and redo stacks to their exact pre-crash depths and labels, then continues appending to the same WAL. A `.checkpoint` is written on open and after every save/clear (which flattens history), keeping the log bounded.
