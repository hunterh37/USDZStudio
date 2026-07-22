# Implementation Plan — Modal Grab/Move Transform (Blender-style G/R/S)

- **Slug:** `modal-grab-transform` (pairs with `research.md` in this folder)
- **Date:** 2026-07-22
- **Source research:** `./research.md`
- **Roadmap slot:** Milestone 1 follow-on (the transform-gizmo family shipped; this adds the keyboard-first *modal* driver onto it) and `specs/viewport.md` §Selection & Gizmos. Depends on the shipped `GizmoMode`/`TranslateGizmoMath`/`RotateGizmo`/`ScaleGizmo` seams and `EditingKit.TransformDragSession`. Unblocks: keyboard-first editing parity; a precision (numeric) transform entry point the inspector's TRS fields don't give in the viewport.
- **Status:** proposed

## Summary

Add a modal transform to the viewport: pressing `G` (grab/translate), `R` (rotate), or `S` (scale) with a prim selected starts a live transform that follows the cursor — no handle click required. While modal, `X`/`Y`/`Z` lock to an axis (`Shift`+axis locks the plane, a repeat toggles world/local), and typed digits enter an exact delta (`G Z 2.4 ⏎`). `Enter`/left-click confirm as a single coalesced undo entry; `Esc`/right-click cancel back to the original transform. A small HUD shows the running delta and active constraint. This is the Blender interaction model layered on top of our existing Maya-style handle gizmos; both coexist.

## Module targets

| Module (`Packages/*`) | Change | New dependency edges | Legal per architecture.md? |
|---|---|---|---|
| **ViewportKit** | New pure value types: `ModalTransform` (state machine), `ModalConstraint`, `NumericEntry`, `ModalTransformKind`. Reuses `GizmoAxis`, `ExtrudeGizmoMath.axisParameter`, `RotateGizmo`/`ScaleGizmo` math. Viewport input layer starts/updates/commits a session. | none new (already → USDCore, MeshKit) | yes — ViewportKit is where camera/gizmo/selection logic lives (`architecture.md` module table) |
| **EditorUI** | Keyboard routing (`.onKeyPress` for `g`/`r`/`s`, axis letters, digits, `.`, `-`, `⏎`, `⎋`, `?`) on the viewport; drives the session and, on confirm, emits the existing `SetTransformCommand` via `TransformDragSession.makeCommand(verb:)`. Renders the HUD string the model produces. New discoverability surfaces: `ShortcutRegistry` (single source of truth), `ShortcutsOverlay` (`?` reference card), `ShortcutHintToast` + pure `ShortcutHintController`. | none new (already → ViewportKit, EditingKit; SessionKit for the hint pref) | yes — EditorUI owns panels/keyboard, already uses `.onKeyPress` (`CommandPaletteView`) |

> No new package → no `dependency-lint.sh`/`architecture.md` change. `SetTransformCommand`/`TransformDragSession` are used **unchanged** — the mutation + coalesced undo already exist. `USDCore`/`MeshKit` untouched.

## Data model / API

```swift
// ViewportKit — all pure, Sendable, unit-testable (holds the ratchet/spec floor).

public enum ModalTransformKind: Sendable { case grab, rotate, scale }   // G / R / S

/// Axis/plane constraint accumulated during a modal session.
public enum ModalConstraint: Equatable, Sendable {
    case free                              // follows cursor in the view plane
    case axis(GizmoAxis, local: Bool)      // X/Y/Z; repeat toggles local
    case plane(GizmoAxis, local: Bool)     // Shift+axis: lock the *excluded* axis
}

/// Typed numeric entry ("2.4", "-3", ".5"); overrides pointer magnitude when non-empty.
public struct NumericEntry: Equatable, Sendable {
    public private(set) var text: String
    public var isEmpty: Bool { text.isEmpty }
    public var value: Double? { Double(text) }
    public mutating func append(_ c: Character)   // digits, one '.', leading '-'
    public mutating func backspace()
    public static let empty = NumericEntry(text: "")
}

/// The modal transform state machine. Seeded from the selection's current TRS +
/// world pivot; every input returns a *proposed* TRS the viewport previews live.
public struct ModalTransform: Equatable, Sendable {
    public let kind: ModalTransformKind
    public let seed: TRS                    // restored on cancel
    public let pivot: SIMD3<Double>         // world-space pivot (median for multi-select)
    public let basis: GizmoBasis            // for local-axis constraints
    public private(set) var constraint: ModalConstraint
    public private(set) var numeric: NumericEntry

    public init(kind: ModalTransformKind, seed: TRS, pivot: SIMD3<Double>, basis: GizmoBasis)

    // Inputs (return self mutated; pure):
    public mutating func setConstraint(axis: GizmoAxis, shift: Bool)  // X/Y/Z, Shift=plane, repeat=local
    public mutating func typeDigit(_ c: Character)
    public mutating func backspaceNumeric()

    /// Proposed transform from a pointer sample. `pointer`/`start` are screen-space;
    /// `ray`/`camera` supply the world projection (same inputs the handle gizmos use).
    public func proposedTRS(pointer: CGPoint, start: CGPoint, ray: CameraRay,
                            viewportHeight: Double) -> TRS

    /// HUD line, e.g. "Move Z: 2.40 m (global)" — rendered by the viewport.
    public var hudText: String { get }
}
```

Confirm path (EditorUI) reuses the shipped seam — no new command:

```swift
// On Enter/LMB: fold the proposed TRS into a TransformDragSession seeded from `seed`,
// then run its single coalesced command through the stack.
let session = TransformDragSession(path: path, startTRS: modal.seed)
session.update(to: proposed)
if let cmd = session.makeCommand(verb: modal.kind.undoVerb) { stack.run(cmd) }   // "Move"/"Rotate"/"Scale"
// On Esc/RMB: discard the session; the live preview reverts to `seed` (no command).
```

## Algorithm

Seeded from selection primary `TRS`, world pivot (median for multi-select — reuse `GizmoPivot` logic), and `GizmoBasis` (world, or the selection's local basis).

1. **Free move (grab, no constraint):** project `pointer` and `start` onto the plane through `pivot` facing the camera; `deltaWorld = unproject(pointer) - unproject(start)`; `TRS.translation = seed.translation + deltaWorld`. (Same view-plane unprojection the pan/translate paths use.)
2. **Axis-constrained move:** reuse `ExtrudeGizmoMath.axisParameter(ray:origin:axis:)` — signed distance along `basis.direction(axis)`; `translation = seed.translation + d · axisDir`. `Shift`+axis (plane): move in the plane whose normal is `axisDir` (drop the normal component of the free delta).
3. **Rotate:** angle = signed screen angle of `pointer` vs `start` about the projected `pivot` (reuse `RotateGizmo` math); axis = constrained axis or the camera view direction when `free`; compose onto `seed` rotation about `pivot`. Numeric entry = **degrees**.
4. **Scale:** factor = `|pointer − pivotScreen| / |start − pivotScreen|`; `free` = uniform, axis = per-axis about `basis`; compose onto `seed`. Numeric entry = **factor** (`1` = identity).
5. **Numeric override:** when `numeric.value != nil`, ignore pointer magnitude and use the typed value as the signed delta (translate: units along the constraint axis, default the last-active axis or X if none; rotate: degrees; scale: factor). Pointer still previews until a digit is typed.
6. **Constraint keys:** `X`/`Y`/`Z` → `.axis`; same axis again → toggle `local`; `Shift`+axis → `.plane`. Changing constraint re-derives from `start` (no accumulated drift).
7. **Confirm:** build final `TRS`, emit one `SetTransformCommand` (§API). **Cancel:** restore `seed`, emit nothing. Losing selection/focus mid-session = cancel.

Edge cases / precision: USD floats are 32-bit — do all math in `Double`, quantize only at command emission (matches `SetTransformCommand`). Degenerate scale start (`pointer == pivotScreen`) → factor 1 (guard divide-by-zero). Empty selection → keypress is a no-op (never a silent transform). Multi-select → pivot = median (respect `GizmoPivot.individual` if set: apply per-prim about each origin, one coalesced command group).

## RealityKit export-profile behavior

Nothing profile-specific. The feature authors ordinary `xformOp:transform`/TRS opinions that already round-trip through the bridge and pass `ComplianceChecker`/`ExportGate` under both `arkit` and `arkit-strict`. No new USD construct, no badge, nothing to degrade or drop. The `roundtrip-gate.sh` invariants over transforms already cover the emitted mutation (it's the same `SetTransformCommand` as handle drags).

## Harness (lands in the SAME PR)

- **Invariants (ViewportKit unit tests, pure — must hold the module's coverage floor):**
  - `NumericEntry` grammar: digit/`.`/`-`/backspace accept/reject table; `"2.4"→2.4`, one dot max, `-` only leading, `value == nil` for `""`/`"-"`/`"."`.
  - `ModalTransform.proposedTRS` parity: axis-constrained grab equals the existing `TranslateGizmoMath` result for the same ray/axis (asserts we reuse, not fork, the math).
  - Cancel neutrality: `seed`-in == proposed-after-cancel (`ModalTransform` produces `seed` when reset). Confirm→`SetTransformCommand` undo restores `seed` exactly (EditingKit round-trip).
  - Numeric override: `G Z 2.4 ⏎` yields `translation.z == seed.z + 2.4` independent of pointer position; rotate degrees→radians; scale factor identity at `1`.
  - Constraint state machine: `X`,`X`→local toggle; `Shift+X`→plane; re-derivation from `start` (no drift) property test over random pointer paths.
  - `hudText` golden strings per kind/constraint/numeric state.
- **`ViewportDragRouter.resolve` matrix (ViewportKit):** every (hit ∈ {handle, selected-body, other-prim, empty}) × (modifiers) × (boxSelectEnabled) → expected `DragIntent`, exhaustively asserted.
- **`ShortcutHintController` (EditorUI, pure `@Observable` + injected clock):** `onSceneAppear` → visible; `tick` past hold → fading → hidden; `onInteraction` dismisses early; once-per-session gating; "don't show" pref suppresses. Full state-machine coverage with a fake clock (no animation timing in tests).
- **`ShortcutRegistry`:** non-empty per group; keys unique within group; every `GizmoMode`/`ModalTransformKind` has a registry entry (guards the "add a shortcut once, it shows everywhere" invariant).
- **Coverage floors:** ViewportKit — all new value types (`ModalTransform`, `ModalConstraint`, `NumericEntry`, `ViewportDragRouter`) **100%** logic (hold the module's current ratchet, raise toward the 90% spec floor per Milestone 7; the pure state machine must be fully covered, mouse-capture glue stays behind existing `coverage:disable` routing markers). EditorUI — `ShortcutHintController`/`ShortcutRegistry` logic covered to hold the EditorUI ratchet. EditingKit — unchanged (no new command), existing `SetTransformCommand`/`TransformDragSession` coverage stays green.
- **Golden files:** none needed (no new rendered surface); `hudText` + `ShortcutsOverlay` content goldens are string asserts, not images. Existing viewport snapshot tests still pass (gizmo layout unchanged).
- **Fuzz corpus:** n/a (no MeshKit topology change).

## Rollout

1. Land `ModalTransform`/`ModalConstraint`/`NumericEntry` + full unit-test suite in ViewportKit (harness first).
2. Wire viewport input: start/update/commit/cancel against the model; render `hudText` overlay + live preview via the existing gizmo `revision` follow.
3. EditorUI keyboard routing (`.onKeyPress`), confirm → `TransformDragSession.makeCommand`; cancel path.
4. Update `specs/viewport.md` §Selection & Gizmos to document the modal idiom alongside W/E/R (separate build PR edits the spec, per skill rules).

## Decisions (locked 2026-07-22)

- **Both idioms ship (Option A).** `W`/`E`/`R` keep selecting the persistent handle gizmo (Maya idiom, unchanged); `G`/`R`/`S` start the modal transform (Blender idiom). No runtime key collision — `W`≠`G`, `E`≠`R`, `R`≠`S`. The only learnability wrinkle is that `R` is *scale-tool-select* but Blender muscle-memory reads `R` as rotate; this is resolved by discoverability UI (below), not by re-binding. Both idioms drive the same `SetTransformCommand` path.
- **Body-drag ships too.** A left-drag that *begins on the currently-selected mesh body* starts an unconstrained modal grab (equivalent to `G` with `.free`). This requires a deterministic left-drag disambiguation policy in the viewport input router (below), because it shares the gesture with camera-orbit and the planned box-select.

### Left-drag disambiguation policy (viewport input router)

The router resolves a left-mouse-down in strict priority; first match wins:

1. **On a gizmo handle** (`anyGizmoMouseDown` hit) → the active handle gizmo claims the drag. *(unchanged)*
2. **On the selected prim's body** (pick ray hits an entity whose `PrimPath` is in `selection`) → start a `.free` `ModalTransform` grab (body-drag). Escape hatch: holding the camera modifier (`Space`/middle-drag, already the "camera in any mode" path) forces orbit even on-body.
3. **On empty space or a non-selected prim** → **box-select marquee** if box-select is enabled, else **camera orbit**. *(box-select is the `specs/viewport.md` stretch item; until it lands, this branch is orbit — body-drag does not depend on marquee existing, it only has to yield to it once it does.)*

This policy is a **pure function** (`ViewportDragRouter.resolve(hit:selection:modifiers:boxSelectEnabled:) -> DragIntent`) so it is unit-tested exhaustively over the hit/selection/modifier matrix and holds coverage without needing an NSView.

## Discoverability UI (single source of truth — anti-clutter)

Goal: users can *find* every hotkey, and *new* users are nudged once, without persistent on-screen chrome. Three surfaces, **one data source**.

### `ShortcutRegistry` — one source of truth

A pure, `Sendable` list of `ViewportShortcut { keys, title, group, symbol }` in EditorUI, the single origin for **all four** consumers: the reference overlay, the transient hint, control tooltips (`.help(...)`), and — when Phase 5's `ActionRegistry`/⌘K lands — the command palette. No hotkey string is ever hand-written in a view; a shortcut added once appears everywhere. Groups: *Transform (modal)* `G/R/S` + `X/Y/Z` + numeric, *Transform (gizmo)* `W/E/R`, *Camera* orbit/pan/dolly/`F`/`A`, *Selection* click/⌥/Esc/⇧I.

### Surface 1 — full reference overlay (`ShortcutsOverlay`, toggled by `?`)

Press `?` (and a small always-present `⌘/?` affordance in a viewport corner + a Help ▸ "Keyboard Shortcuts" menu item) toggles a translucent, dismissible card grouping the whole registry by `group`. Zero persistent chrome — it's absent until summoned, `Esc`/`?`/click-away closes it. This is the "one place that shows all hotkeys."

### Surface 2 — transient hint (`ShortcutHintToast`, fade in → auto-fade on scene appear)

When a scene first appears in the viewport, a small toast fades in (~0.4s) showing the *essential* line — e.g. `G move · R rotate · S scale · drag to grab · ? all shortcuts` — holds ~4s, then fades out (~0.6s); any viewport interaction dismisses it early. The **decision logic is a pure `@Observable ShortcutHintController`** with an **injected clock** (`onSceneAppear()`, `onInteraction()`, `tick(now:)` → `opacity`/`isVisible`), so the show/hold/fade/once-per-session gating is fully unit-testable; only the actual opacity animation is view-side. Shown once per document-open by default (session-scoped flag), with a "Don't show hints" preference that persists via SessionKit.

## Risks & open questions

- **Focus/first-responder:** the viewport must hold keyboard focus for `.onKeyPress` to fire; ensure it claims focus on click without stealing it from text fields (inspector TRS entry). Same concern the command palette already handles.
- **`R` semantic overlap (mitigated, not removed):** `R`=scale-tool vs. Blender's `R`=rotate. Mitigated by the reference overlay + transient hint making both explicit; revisit only if user testing shows it trips people.
- **Box-select ordering:** body-drag (priority 2) ships before marquee (priority 3); when marquee lands it slots in at priority 3 with no change to body-drag. Confirm we're comfortable shipping body-drag ahead of marquee (recommended — they don't conflict, marquee only ever occupied the empty-space branch).

## Acceptance criteria

- [ ] With a prim selected, `G`/`R`/`S` start a live modal transform that follows the cursor; `Enter`/LMB confirm, `Esc`/RMB cancel to the original transform. `W`/`E`/`R` handle gizmos still work unchanged (both idioms coexist).
- [ ] `X`/`Y`/`Z` axis lock, `Shift`+axis plane lock, axis-repeat local toggle, and typed numeric deltas (`G Z 2.4 ⏎`) all work; HUD shows delta + constraint.
- [ ] A left-drag beginning on the selected body starts an unconstrained grab; empty/other-prim drag orbits (or marquees once box-select lands); on-handle drag still drives the gizmo. Router policy is pure + exhaustively tested.
- [ ] Confirm emits exactly one coalesced undo entry ("Move"/"Rotate"/"Scale"); cancel emits none and leaves the stage byte-identical.
- [ ] `?` toggles a `ShortcutsOverlay` listing every registered hotkey by group; a transient `ShortcutHintToast` fades in on scene appear, holds, and auto-fades (dismiss-on-interaction, once per session, suppressible). Both read from `ShortcutRegistry` — no hand-written key strings in views.
- [ ] ViewportKit harness green with new value types 100%-covered; ViewportKit + EditorUI ratchets held; existing gizmo/snapshot tests unaffected.
- [ ] No export-profile impact (authors only standard TRS; `roundtrip-gate.sh` stays green).
