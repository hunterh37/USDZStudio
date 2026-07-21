# Animation & Rigging UI Specification — Gizmos, the Animator Dock, and MCP-Manual Symmetry

Companion to `specs/animation-rigging.md` (the RigKit/`.rig` data + agent contract) and `specs/articulation-mechanisms.md` (rigid joints). That spec answers *what an agent authors*; **this spec answers *how a human authors the same thing by hand*, and how the two share one surface.** It also fixes the layout question head-on: the animation system is **not** all-in-viewport, and it is **not** a single new panel — it is a deliberate three-zone split grounded in a principle the whole design obeys.

## The governing principle — space, time, and value are three different editors

Every mature character tool (Maya, Blender, Cinema 4D) converges on the same division because it maps to three orthogonal things a user manipulates, and no single widget serves more than one well:

| Domain | What the user does | Right surface | Why not elsewhere |
|---|---|---|---|
| **Space** | pose a bone, aim an IK effector, place a hinge, paint weights | **Viewport gizmos & overlays** | You cannot pose a character by typing Euler angles; direct manipulation in 3D is the whole point. |
| **Time** | key, retime, ease, layer clips, sequence states | **The Animator Dock** (bottom) | Time is not a spatial axis; keys/curves/clips are inherently 2D track/graph editors. Overlaying them on an orbit camera is unusable. |
| **Value** | joint limits, weights, constraint params, the bone-name map | **The Inspector** (right, existing) | Exact numbers and structured tables want a form, not a 3D handle or a timeline. |

So the answer to "new bottom panel, or all in the viewport?" is: **both, plus the inspector — each owns exactly one domain.** Posing lives in the viewport (dragging numeric fields to pose is misery). Sequencing lives in a new bottom **Animator Dock** that is the current transport bar *grown up* (evolution, not a new concept — and it reuses `PlaybackController`/`PlaybackTransport` verbatim). Properties live in new Inspector tabs. This keeps normal prim-editing uncluttered: the animation UI only materializes in **Rig Mode** (progressive disclosure, the same discipline that already auto-hides the transport bar).

## Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│ Toolbar: select/move/rotate/scale │ ★RIG MODE │ debug view │ env │ ⌘K │
├──────────┬───────────────────────────────────────────┬───────────────┤
│ Outliner │                                           │  Inspector    │
│ + Skeleton│           Viewport                        │  (Joint /     │
│   joint  │   · bone overlay (click-to-select)        │   Weights /   │
│   tree   │   · limit-aware rotate gizmo (FK)         │   Rig map /   │
│ + Clips  │   · IK effector + pole-vector handle      │   Clip /      │
│  section │   · motion trail w/ draggable key beads   │   Constraint) │
│          │   · onion-skin ghosts · weight heatmap    │               │
│          ├───────────────────────────────────────────┤ [motion-Q     │
│          │  ★ ANIMATOR DOCK (expands from transport)  │  meter ●]     │
│          │  ┌─ Dope │ Curves │ Clips/NLA │ States ─┐  │               │
│          │  │ tracks │  ◇──◇────◇ keyframes         │  │               │
│          │  │ (per   │  playhead │ ruler (timecode) │  │               │
│          │  │  bone) │  ✨Smooth  ⏮◀ ▶ ⏭  loop  1.0×│  │               │
│          │  └────────┴──────────────────────────────┘  │               │
├──────────┴───────────────────────────────────────────┴───────────────┤
│ Utility drawer (Log │ Python │ Diagnostics) — sibling of Animator Dock │
├────────────────────────────────────────────────────────────────────── ┤
│ Status: bone path · FK/IK · motion-Q ●82 · units · validation · zoom   │
└────────────────────────────────────────────────────────────────────────┘
```

The **Animator Dock** and the existing utility **Drawer** are sibling tab-groups sharing the bottom region. Entering Rig Mode auto-focuses the Animator Dock and expands it from its collapsed height (which is *exactly* today's transport bar) to the working height; leaving Rig Mode collapses it back. Nothing about the existing Log/Python/Diagnostics drawer changes.

## Rig Mode — a top-level interaction mode

A new mode alongside select/move/rotate/scale (auto-entered when a `Skeleton` prim or a joint is selected; togglable in the toolbar and via a shortcut). While active it re-skins three surfaces at once, which is what makes the whole thing feel like a coherent tool rather than scattered features:

- **Selection primitive becomes the bone**, not the prim. Click picks a joint (raycast against bone proxies, reusing the existing viewport raycast-selection path); the existing hierarchy-aware walk (double-click up the chain, breadcrumb in the status bar) now walks the *joint* hierarchy.
- **The gizmo defaults to rotate** (joints overwhelmingly rotate), with IK handles shown for chains that have them. W/E/R still switch.
- **The Animator Dock and the Joint/Rig inspector tabs appear.**

This mode gate is the single most important UX decision: it means a user opening a static prop never sees a frame of animation chrome, and a user opening a rigged character is dropped straight into a posing environment.

## Viewport — the spatial workspace (gizmos & overlays)

All of this reuses the shipped gizmo seam (`GizmoAxis` + `CameraRay` + the W/E/R hit-test/drag infrastructure, snapping, one coalesced `SetTransformCommand`/`EditCommand` per drag). New pieces:

### 1. Skeleton overlay + bone picker
Joints drawn as shaded octahedral "bones" (RealityKit overlay entities, culled with the mesh). Click-to-select via raycast against the bone proxies; selected bone uses the existing outline post-process. **Color encodes meaning**: FK vs IK chains, a left/right symmetry hue split, root/hips emphasized. Bone display size auto-scales to model bounds. Toggle: solid bones / stick figure / hidden.

### 2. Limit-aware rotate gizmo (FK posing) — *clever, and the realism enforcer*
The rotate ring for a joint draws the **authored rotation limit as a filled wedge**, and the drag **clamps at the limit and visibly resists past it**. You physically cannot hyperextend an elbow. The joint limit stops being an invisible number in a form and becomes a felt, seen constraint — this is a large fraction of what "realistic" means, delivered by the gizmo itself. Angle-snap (⇧) already exists and carries over.

### 3. IK effector + pole-vector handle
A translate gizmo on the effector (hand/foot). Dragging it runs `solve_ik` **live, per-frame, deterministically** and poses the whole chain (the solver is pure; the drag is a single undo group). A **pole-vector knob** on a dotted line from the mid-joint controls elbow/knee direction — drag it to rotate the chain plane, the most intuitive control there is for "which way does the knee point." A small FK⇄IK blend slider sits on the handle (and in the inspector). A non-converging solve surfaces as a subtle amber tint on the effector (the `SolveResult.converged == false` from the spec), never a silent bad pose.

### 4. Pivot / hinge placement gizmo (rigid articulation + joint pivots) — *clever*
For MechanismKit hinges and for setting a joint's pivot: a mode where you **drag a point onto the mesh and it snaps to edges / vertices / bbox seams** (reuses raycast + snapping), drawing the hinge as an infinite axis line with a live rotation-preview arc. Placing a hinge becomes "click the rear edge of the lid," no numeric entry — the direct manual counterpart to the agent reading the bbox and passing `pivot:[…]` to `create_joint`.

### 5. Motion trail with draggable keyframe beads — *the signature feature*
The selected joint/effector's swept path over time is drawn in 3D as an editable polyline, with a **bead at each keyframe you can grab and drag in space** — editing the *temporal* keyframe's value with a *spatial* handle. Tangent smoothness shows as the curvature of the trail. This is the bridge that makes the viewport and the dock feel like one instrument: you can author motion without ever looking at a curve editor, or refine it in the curve editor and watch the trail update.

### 6. Onion skinning
Translucent ghost poses at ±N frames (and an optional persistent **rest/default-pose ghost** for reference), driven from a dock toggle. Standard, cheap, and enormously helpful for judging arcs and spacing.

### 7. Weight paint sub-mode
The selected mesh becomes an influence **heatmap (blue→red)** for the selected joint; a **brush cursor ring** paints on the surface by dragging (raycast → triangle → weighted falloff), with add / subtract / **smooth** brushes, radius/strength, automatic normalize, and a **symmetry-mirror toggle** that paints the opposite side simultaneously. This is the manual path parallel to `solve_weights`/`paint_weights`; both emit the same weight-table commands.

### 8. Auto-rig "confirm & adjust" handles
After `auto_rig` proposes a skeleton, each joint shows as a **sphere handle you drag to nudge**, with labeled landmark pins (head / hands / feet); accepting re-solves weights as one undoable command (spec Phase 14). The manual user and the agent both land in this same confirm step.

## The Animator Dock — the temporal workspace

The transport bar, promoted to a full editor. A segmented mode control (mirroring the debug-view control) switches four views over a **shared playhead and shared track-list gutter** (the gutter is synced to the bone selection / hierarchy filter):

1. **Dope Sheet** (default) — keys as diamonds on per-bone / per-channel tracks; box-select, move, scale-to-retime, copy/paste, ripple. A summary track at the top aggregates all keys for fast global retiming.
2. **Curve Editor** — F-curves with bezier tangent handles; **the** surface for smoothness. Tangent presets (auto / spline / flat / stepped / linear) and a **✨ Smooth button that runs the jerk-minimizing pass tied to the spec's MotionQuality metric** — the same math the agent's gate uses, one click for the human.
3. **Clips / NLA** — clips as blocks on layered tracks; drag to reorder, trim edges, **overlap → automatic crossfade** (blend region shown hatched), additive layers stacked above the base. This is the linear face of the Phase 15 blend surface.
4. **State Machine** — a node graph of states (clips / blend-trees) and transitions (edges with conditions) for Phase 15. Graph-shaped but kept in the dock so all time-domain authoring lives in one place.

The ruler honors `timeCodesPerSecond` with a frame/second toggle. Transport (play/pause/loop/speed/scrub) is unchanged behavior — it still resolves to "seek the `AnimationResource` to time T and hold paused," so what plays is exactly what a RealityKit app will show. Playhead navigation: ⏮/⏭ jump prev/next key; the playhead snaps to keys with a modifier.

## Inspector — the value workspace (new tabs via `InspectorPanelProvider`)

- **Joint** — name **plus the canonical mapped-name badge with confidence** (from `identify_skeleton`), per-axis rotation limits shown as mini dials (drag to set — feeds the limit wedge on the gizmo), FK/IK blend, parent, mirror partner.
- **Skin / Weights** — influence list for the selected vertex or joint, weight values, normalize / prune / mirror, and the profile max-influence cap.
- **Rig** (skeleton root) — **the canonical humanoid map table**: each canonical bone → mapped joint + confidence, with a dropdown to fix low-confidence/unmatched rows. This is the manual twin of `identify_skeleton`: the agent proposes, the table shows reds, the user corrects. Retarget source picker lives here too.
- **Clip** — selected clip's range, loop, blend weight, additive toggle.
- **Constraint** — parent/point/orient/aim/scale params, weight, target picker.

All fields commit through EditingKit commands (one undo group per scrub), exactly like the existing Transform tab.

## Outliner additions

Skeleton rows (icon already exists) expand into the **joint hierarchy** with mapped-name badges and a mapped/unmapped filter; joint selection syncs the bone overlay. A new **Clips** section (peer of the existing Materials/Variants sections) lists animation clips with an active-clip radio.

## MCP ⇄ Manual symmetry — one surface, two drivers

This is the crux of "Claude-driven **and** fully manual," and it falls out of two facts already true in the codebase: **(a)** every `.rig` tool and every UI control emit the *same* EditingKit commands, and **(b)** the app hosts the MCP session (`specs/agent-live-editing.md`), so agent edits land in the live document and viewport. Consequences we lean into:

- **Live echo.** When Claude runs `solve_ik`, the effector gizmo *moves in the viewport* in real time; when Claude authors keys, they appear on the dope sheet with a brief agent-attribution highlight (the existing MCP activity stream, surfaced in the animation context). Human and agent edits interleave freely and share one undo stack.
- **One-click agent bridges in the manual UI** — buttons that hand a manual selection to agent intelligence through the same tools: **✨ Smooth this** (key range → smoothing), **Identify bones** (unmapped skeleton → `identify_skeleton`), **Fix foot-slide**, **Auto-rig this mesh**. The user never has to "switch to Claude"; the intelligence is on the toolbar.
- **The motion-quality meter — the self-validation gate, made human-visible.** The dock shows a small live badge of `measuredMotionQuality` with sub-meters (smoothness / foot-slide / interpenetration / limit-compliance), green/amber/red; clicking it **jumps the playhead to the worst frame.** This is the exact number the agent's continue-gate enforces — so the human is coached by the same objective standard the agent is held to. It turns "is this smooth/realistic?" from taste into a shared readout. **This is the single highest-value, most differentiating UI element in the plan.**

## Data flow (one funnel, provable)

```
Viewport gizmo  ┐
Animator Dock   ├─▶ EditingKit command ─▶ EditSession/stage ─▶ ViewportScene diff ─▶ RealityKit
Inspector field ┤        (undoable)            (source of truth)      (WYSIWYG)
.rig MCP tool   ┘
                     ▲                                    │
              RigKit (pure math: FK/IK, weights,          └─▶ RigKit.MotionQuality ─▶ motion-Q meter
              retarget, MotionQuality — invariant-tested)       (same score the agent's gate uses)
```

Bone overlay geometry is projected from the `RigKit.Skeleton`; the playhead has a single source (`PlaybackController`); the gizmo seam, raycast selection, snapping, and outline highlight are all reused, not reinvented.

## Clever-solutions index (quick reference)

Limit-aware rotate wedge (realism enforced by the gizmo) · draggable motion-trail key beads (edit time in space) · pole-vector plane line · onion skinning + rest-pose ghost · click-to-place hinge with mesh snapping · weight-paint heatmap with symmetric brush · **live motion-quality meter shared by human and agent** · ✨Smooth / Identify-bones / Fix-foot-slide one-click agent bridges · symmetry mirroring across pose/weights · snap-to-key playhead + key-jump navigation · FK⇄IK blend on the handle.

## Phasing (tracks `specs/animation-rigging.md` / ROADMAP Phases 10, 13–15)

- **Phase 10 (foundation UI):** Rig Mode shell; Animator Dock with **Dope Sheet + Curve Editor**; bone overlay + picker; limit-aware rotate gizmo (FK posing); Joint & Weights inspector tabs; weight-paint sub-mode; motion trail + onion skin; the motion-quality meter (smoothness/limit sub-scores available first).
- **Phase 13 (rigging):** IK effector + pole-vector handles; FK/IK blend; constraint inspector; control-handle rendering.
- **Phase 14 (auto-rig):** confirm-&-adjust joint handles + landmark pins; "Auto-rig this mesh" bridge.
- **Phase 15 (retarget/library):** Clips/NLA and State-Machine dock modes; the Rig canonical-map table + "Identify bones"; foot-slide sub-meter + "Fix foot-slide" bridge; retarget source picker.

## Open questions (for the user)

1. **Dock vs Drawer real estate** — sibling tab-groups sharing the bottom (proposed), or should Rig Mode fully take over the bottom region and float the utility drawer?
2. **State Machine home** — inside the Animator Dock (proposed, keeps time-domain together) or a dedicated full-window graph mode like a shader editor?
3. **Weight paint** — in-viewport heatmap+brush (proposed) is a substantial sub-mode; acceptable for Phase 10, or defer manual paint to Phase 13 and ship only `solve_weights` first?
