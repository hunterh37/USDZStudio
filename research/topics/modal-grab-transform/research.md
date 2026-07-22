# Research — Modal Grab/Move Transform (Blender-style G/R/S)

- **Slug:** `modal-grab-transform`
- **Date:** 2026-07-22
- **Question:** Our viewport has camera modes (rotate/zoom/pan) and handle-drag transform gizmos (W/E/R translate/rotate/scale), but no *modal* "grab" transform — the keyboard-initiated, cursor-follows-object interaction every keyboard-driven DCC ships (Blender `G`/`R`/`S`). How do the major DCCs implement it, and what is the smallest RealityKit-first, USD-native version we should build?
- **Status:** planned
- **Related topics:** extends Milestone 1 (transform-gizmo family, done) and `specs/viewport.md` §Selection & Gizmos; sibling to `lattice-deformer` (both drive `SetTransformCommand`/coalesced-undo through the gizmo seam).

## TL;DR

The two dominant object-transform interaction models are Maya's **persistent manipulator** (select tool → drag a handle) and Blender's **modal transform** (press `G`/`R`/`S` → the object is *immediately* transforming and follows the cursor, with `X`/`Y`/`Z` axis locks, typed numeric deltas, and `Enter`/`Esc` confirm/cancel). We already ship the Maya model (the W/E/R handle gizmos). The gap the user spotted is the modal model — the fastest path for a keyboard-driven user, and the single most-requested Blender ergonomic when it's missing. We should add a **modal transform state machine as pure math in ViewportKit** that reuses the existing `GizmoAxis`/axis-parameter math and drives the *same* `TransformDragSession` → `SetTransformCommand` coalesced-undo path the handle gizmos already use. No new renderer features, no new module, no USD-schema surface — it is an input/authoring aid that bottoms out in transforms RealityKit renders natively.

## Comparison set

| Tool / source | How it solves this | Cost / complexity | License | Applicability to us |
|---|---|---|---|---|
| **Blender** (Grab/Move operator; Numeric Input manual) | `G`/`R`/`S` enter a *modal operator*: the transform starts immediately and tracks mouse delta; `X`/`Y`/`Z` lock to a global axis, second press (`XX`) toggles local, `Shift`+axis excludes that axis; typing digits enters an exact delta (`G Z 2.4 ⏎`); `Enter`/LMB confirm, `Esc`/RMB cancel to the original transform. | Low math; the ergonomics/state machine *is* the work. | GPL-2.0+ | **Adopt the interaction, clean-room.** Never read Blender source; the behavior is documented and obvious. |
| **Maya** (Move Tool / manipulators) | Persistent manipulator gizmo; click a handle to make it active, then drag anywhere. No keyboard-initiated modal grab; keyboard `W`/`E`/`R` *select the tool*, they don't start a transform. | — | proprietary | This is the model **we already have** (our W/E/R handle gizmos). Confirms the gap is the modal path, not the handle path. |
| **Godot `gsr_for_godot` addon** (z1dev) | A third-party addon that re-adds exactly Blender's `G`/`S`/`R` + axis + numeric input to Godot's editor — evidence the modal model is a discrete, self-contained feature layerable on top of an existing manipulator, not a whole-editor rewrite. | Small addon. | **GPL-3.0** | Confirms scope & feasibility. **Do not read its code** (GPL) — we already have the behavior from Blender's docs. |
| **usdview / Reality Composer Pro** | Manipulator/handle model only; no modal grab. | — | Apache-2.0 / proprietary | Neither raises the bar here; parity is with Blender. |

> All external claims cited inline below; primary sources are Blender's manual and Maya's user guide.

## State of the art

The modal transform is a small, well-specified state machine over pointer motion. Blender's Grab/Move: pressing `G` puts the object into a live move that "moves freely according to the mouse pointer's location and camera," and precision is layered on top via axis constraint keys and numeric input ([Blender manual, Numeric Input](https://docs.blender.org/manual/en/latest/scene_layout/object/editing/transform/control/numeric_input.html); [Blender 2.79 transform basics](https://docs.blender.org/manual/en/2.79/editors/3dview/object/editing/transform/basics.html)). The precision layer:

- **Axis constraint:** after `G`, press `X`/`Y`/`Z` to lock motion to that world axis; `Shift`+axis locks the *other* two (plane-constrain); a second press of the same axis toggles global↔local basis.
- **Numeric input:** once modal, typed digits set an exact magnitude — `G Z 2.4 ⏎` moves 2.4 units on Z. Documented sequence: shortcut → (optional axis) → number → confirm ([Blender manual, Numeric Input](https://docs.blender.org/manual/en/latest/scene_layout/object/editing/transform/control/numeric_input.html); [Precision work in Blender](https://blendermama.com/precision-work-in-blender.html)).
- **Confirm/cancel:** `Enter`/LMB commit; `Esc`/RMB restore the pre-transform value.

The screen→world mapping for the free (unconstrained) move is the same math our handle gizmos already do for a single axis: project the pointer ray onto a motion plane / axis line and take the delta. Rotate maps screen angle about the pivot; scale maps radial pointer distance about the pivot. We already have `GizmoAxis`, `TranslateGizmoMath`, `RotateGizmo`, `ScaleGizmo`, and the shared `ExtrudeGizmoMath.axisParameter` seam — the modal transform is a **new front-end onto existing math**, not new math.

Contrast with Maya, whose manipulators require clicking a handle first and never start a transform from a bare keypress ([Maya Move Tool](https://download.autodesk.com/global/docs/maya2014/en_us/files/Basics_Tools_Move_Tool.htm); [Maya Use manipulators](https://download.autodesk.com/global/docs/maya2014/en_us/files/Transforming_objects_Use_manipulators.htm)). We ship the Maya model already; adding the Blender model gives keyboard-first users the fast path without removing the discoverable handle path.

## Recommended approach for OpenUSDZEditor

Build a **modal transform session** as a pure value-type state machine in **ViewportKit** (`ModalTransform`), mirroring the existing `TransformDragSession` idiom in EditingKit but keyed off keyboard + raw pointer motion instead of a handle hit-test:

1. A keypress (`G`/`R`/`S`, chosen to sit *beside* the existing W/E/R tool-mode keys — see open question on binding) starts a `ModalTransform` seeded from the selection's current `TRS` and pivot. **Reuse the existing tool-mode gizmos for the confirmed result**; the modal session is an alternative *driver*.
2. Pointer motion feeds `ModalTransform.update(pointer:)`, which returns a proposed `TRS` delta using the existing axis/plane/pivot math. The viewport applies it as a live preview exactly like a handle drag (the gizmo already "follows the object it moves" via `revision`).
3. `X`/`Y`/`Z`, `Shift`+axis, and a double-tap local toggle mutate the session's `Constraint`. Typed digits (with `.`, `-`, and backspace) accumulate a `NumericEntry` that, when non-empty, *overrides* the pointer-derived magnitude.
4. `Enter` confirms → emit one `SetTransformCommand` via the existing `TransformDragSession.makeCommand(verb:)` path so undo is a single coalesced "Grab"/"Rotate"/"Scale" entry, identical to handle-drag undo. `Esc` cancels → restore seed `TRS`, emit nothing.
5. A lightweight header/HUD string (e.g. `D: 2.40 (Z global)`) is produced by the pure model for the viewport to render — no new UI framework surface.

This keeps all logic in ViewportKit (unit-testable → holds its ratchet/spec floor), reuses EditingKit's coalesced-undo command unchanged, and adds zero renderer or USD-schema surface.

### Rejected alternatives

- **Reimplement as a new EditingKit command type** — rejected: the modal session is *interaction/preview* state, not a persistable mutation; the actual mutation is already perfectly served by `SetTransformCommand`. Putting live pointer state in EditingKit would blur the command layer and duplicate `TransformDragSession`.
- **Free-drag "click the body and move it" only (no keyboard, no numeric/axis)** — rejected as the *primary* ask: it's the shallow half of the feature. We can offer body-drag as the unconstrained default *inside* the same modal session (start-on-`G`), but the numeric/axis precision is the part that makes it worth building and the part users miss.
- **Read Godot `gsr` or Blender source to match exactly** — rejected on license (GPL). Behavior is fully specified by Blender's public docs; clean-room from the docs.
- **A general-purpose modal-operator framework** (Blender's whole modal system) — rejected as scope creep toward a general DCC; we implement exactly three transforms behind one small state machine.

## RealityKit / constraint reconciliation

- **Renderer:** nothing new to render. The confirmed result is a `TRS` on a prim — RealityKit renders it natively; the live preview is the same transform applied to the projected entity that handle-drags already mutate.
- **ShaderGraph/Metal:** unaffected. The optional HUD text is a SwiftUI overlay, not a shader.
- **Module deps:** all changes land in **ViewportKit** (pure math + the existing viewport input layer) and **EditorUI** (keyboard routing via `.onKeyPress`, already used in `CommandPaletteView`). Both already depend on the seams used. No new package, no `dependency-lint.sh`/`architecture.md` change.
- **arkit / arkit-strict export:** irrelevant to export — the feature only authors ordinary `xformOp` transforms that already round-trip through the bridge and pass `ComplianceChecker`. `ExportGate` sees no new construct. Degradation is a non-issue: there is nothing profile-specific to degrade.
- **No general-DCC creep:** three fixed transforms, one state machine, reusing shipped math. We are not adding a node graph, snapping-everything, or a modal-operator SDK.

## License & provenance notes

- **Blender** manual (GPL-2.0+ software; docs CC-BY-SA): we borrow the *documented interaction contract* (key sequence, axis-lock semantics, numeric-input grammar) — ideas only, no code. Clean-room.
- **Godot `gsr_for_godot`**: **GPL-3.0**. Explicitly **not** read for implementation; cited only as evidence the feature is a discrete, layerable addon.
- **Maya** docs: proprietary; used only to characterize the manipulator model we already match.

## Open questions

- **Key binding vs. our W/E/R tool-mode keys.** Blender uses `G`/`R`/`S` to *start a transform*; we use `W`/`E`/`R` to *select the persistent gizmo tool* (Maya idiom, `GizmoMode.shortcut`). Recommend `G`/`R`/`S` for the modal action so both idioms coexist without collision (`G` is free), and `G` with no prior tool defaults to translate. A human should confirm we want both idioms rather than picking one house style.
- **Body-drag default.** Should a plain click-drag on the selected body (no keypress) also start an unconstrained modal move (the literal "object grabbing" phrasing)? It's discoverable but risks fighting box-select/marquee (a `specs/viewport.md` stretch item). Recommend keyboard-initiated first; revisit body-drag after box-select lands.
- **Rotate/scale numeric units** (degrees vs radians; scale factor vs percent) — match Blender: degrees for rotate, factor for scale.

## Sources

- Blender manual — Numeric Input — https://docs.blender.org/manual/en/latest/scene_layout/object/editing/transform/control/numeric_input.html (accessed 2026-07-22)
- Blender 2.79 manual — Transform basics (Grab/Move) — https://docs.blender.org/manual/en/2.79/editors/3dview/object/editing/transform/basics.html (accessed 2026-07-22)
- Precision work in Blender — https://blendermama.com/precision-work-in-blender.html (accessed 2026-07-22)
- Maya User's Guide — Move Tool — https://download.autodesk.com/global/docs/maya2014/en_us/files/Basics_Tools_Move_Tool.htm (accessed 2026-07-22)
- Maya User's Guide — Use manipulators — https://download.autodesk.com/global/docs/maya2014/en_us/files/Transforming_objects_Use_manipulators.htm (accessed 2026-07-22)
- z1dev/gsr_for_godot (GPL-3.0; not read for implementation) — https://github.com/z1dev/gsr_for_godot (accessed 2026-07-22)
