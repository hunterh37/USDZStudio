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
| `SetAttributeCommand` | generic typed attribute set; captures prior value for undo |
| `RenamePrimCommand` | validates USD name legality; updates selection |
| `ReparentPrimCommand` | preserves world transform option (recomputes local xform against new parent) |
| `SetTransformCommand` on child prims | works at any depth of the hierarchy; if the prim isn't Xformable (bare Mesh), an Xform op is authored on it directly — moving a wheel inside a car "just works" |
| `DuplicatePrimCommand` / `DeletePrimCommand` | delete = deactivate + tombstone for undo (true removal on save) |
| `SetVisibilityCommand` | Hide/show part: authors `visibility = invisible` — part remains in the exported file and is toggleable at runtime in RealityKit |
| `SetActiveCommand` | Disable part: `active = false` — prim excluded from composition and from export (distinct from Hide; UI copy makes the difference explicit) |
| `CreatePrimCommand` | Xform/Scope/Material creation |
| `SetMaterialBindingCommand` | mesh ↔ material |
| `SetMaterialInputCommand` | PreviewSurface param incl. texture path swap |
| `SetVariantSelectionCommand` | variant switching (undoable) |
| `SetStageMetadataCommand` | upAxis, metersPerUnit, defaultPrim… |
| `ScaleFixCommand` | composite: computes uniform scale to target size |
| `CompositeCommand` | ordered children, single undo entry (used by scripts & quick-fixes) |

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
- Crash safety: journal of serialized commands since last save written to app support; offer replay on relaunch after crash.
