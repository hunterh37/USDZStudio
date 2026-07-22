# ViewportKit Specification — RealityKit Viewport

## Scope

The center viewport: rendering, camera, selection, gizmos, environments, debug modes, playback. Built on RealityKit (`ARView` in non-AR mode / `RealityView` on macOS 15+), Metal for overlay passes.

## Rendering

- **Fast path:** unmodified USDZ loads via `Entity(contentsOf:)` — Apple's loader gives best material/skinning fidelity. The file is a *seed*, not the source of truth: the loaded tree establishes a baseline and every subsequent change arrives as a diff against it.
- **Edit path:** the document projects the live stage into a `ViewportScene` (`EditorDocument.viewportScene`); `SceneGraphDiff` reduces successive scenes to minimal entity operations (insert / remove / update mesh / transform / enablement), which `SceneGraphApplier` carries onto the entity tree via a per-prim entity map (`PrimPath → Entity`).
- **Two provenances, one tree.** Loader-backed entities keep their file materials, textures and skinning — the applier never re-meshes them, and the existing prune / live-transform / material-override channels own them. Prims the file never contained (library inserts, scripted or agent-authored prims) are *synthesized* from `ViewportMeshData` and owned end to end by the applier. Synthesized prims currently carry a neutral `PhysicallyBasedMaterial` until the document authors a material opinion for them; projecting full material bindings for synthesized geometry is a follow-up.
- Visibility is resolved with USD inheritance (`UsdGeomImageable`): an invisible prim disables its whole subtree.
- Features USD expresses but RealityKit can't render (e.g. some MaterialX nets, purposes, custom schemas) are **badged in the outliner**, not silently dropped — the stage remains the truth. This is a diagnostic aid, not a feature area: since the viewport IS RealityKit, **what you see is exactly what a user's RealityKit app will render** — making the viewport itself the ultimate compatibility test. Badges exist so incoming files from other tools can be identified and *converted toward* RealityKit compatibility (via validation quick-fixes), never as support for authoring exotic USD.

## Camera

- Turntable orbit (LMB-drag / one-finger), pan (⇧ or two-finger), dolly (scroll/pinch), first-person WASD fly mode (toggle).
- `F` frame selection, `A` frame all; numpad-style ortho presets (front/top/right, ⌘1/2/3); perspective/ortho toggle.
- FOV, near/far clip in View menu; camera bookmarks (save/recall named views — feeds thumbnailing).

## Environment & Lighting

- IBL presets bundled (studio, outdoor, neutral gray, pure white) + drag-in custom `.hdr`/`.exr`.
- Exposure slider, environment intensity, background: environment / solid color / transparent checkerboard.
- Optional key light with shadow for AR-preview realism; ground plane with contact shadow (matches QuickLook look).

## Debug View Modes (toolbar segmented control)

- Shaded (default) · Wireframe overlay · Normals · UV checker · Matcap · Albedo-only · Roughness/Metallic grayscale · Overdraw heatmap (stretch)
- Implemented via material swaps on the projection entities (debug materials generated once, cached).

## Selection & Gizmos

- Click = raycast → prim selection (syncs outliner/inspector); ⌘-click multi-select; box select (stretch).
- **Hierarchy-aware selection for multi-part assets:** single click selects the deepest hit mesh prim (the wheel); repeated double-click walks up the ancestor chain (wheel → axle group → car); ⌥-click jumps straight to the top-level model prim. Esc walks back down/deselects. A breadcrumb of the selected prim's ancestry shows in the status bar — click any segment to select that level.
- **Isolate mode (⇧I):** solo selected prims; everything else ghosts to 10% opacity or hides (toggle). Implemented on the session layer (view-only state) so it never dirties the document.
- Hidden/deactivated prims render ghosted when "show disabled" is on in View menu, so users can find and re-enable parts visually.
- Selection highlight: outline post-process (Metal overlay) — enterprise subtle, not glow-spam.
- Gizmos: translate/rotate/scale (W/E/R), local/world toggle, snapping (grid, angle) with ⇧ modifier. Gizmo drags emit `SetTransformCommand` continuously with a single undo group per drag.
- **Modal transform (Blender idiom, coexists with the handle gizmos):** `G`/`R`/`S` start a live grab/rotate/scale that follows the cursor with no handle click; `X`/`Y`/`Z` lock an axis (repeat toggles world↔local, ⇧+axis locks the plane); typed digits enter an exact delta (`G Z 2.4 ⏎`); `⏎`/left-click confirm as one coalesced undo entry, `⎋`/right-click cancel back to the original transform. A left-drag beginning on the *selected* body starts an unconstrained grab (body-drag); the left-drag priority is a pure, exhaustively tested router (`ViewportDragRouter`: handle → body-grab → marquee/orbit). The state machine (`ModalTransform`/`ModalConstraint`/`NumericEntry`, ViewportKit) is pure and reuses the handle gizmos' axis/angle math; a HUD line shows the running delta + constraint.
- **Hotkey discoverability:** one `ShortcutRegistry` (EditorUI) is the single source of truth for all viewport hotkeys; `?` (and Help ▸ Keyboard Shortcuts / the viewport corner affordance) toggles a translucent reference card grouping the whole registry, and a transient hint toast (pure `ShortcutHintController`, injected clock; once per session, suppressible via the persisted `showHotkeyHints` preference) fades in on scene appear.

## Animation Playback

- Transport bar (bottom of viewport, auto-hides when stage has no animation): play/pause, scrub, loop, playback speed, frame counter honoring stage timeCodesPerSecond. Implemented: transport state is the pure, unit-tested `PlaybackTransport` value type (advance/loop/clamp/scrub math, ViewportKit); `PlaybackController` (EditorUI, `@Observable`) drives it from a display-link tick and exposes the seconds-from-start playhead. The viewport seeks the loaded entity's `AnimationResource` to that time and holds it paused, so every transport action reduces to "show the pose at time T" (deterministic sampled poses).
- Skeletal + transform animations via RealityKit `AnimationResource` (currently the first authored clip); per-animation selection when multiple clips exist is a follow-up.

## Stats HUD (toggle, top-right)

Triangles · vertices · meshes · materials · textures + texture memory · file size · bounds dimensions in cm/m (crucial for AR scale sanity).

## Performance Targets

- 60fps orbit on 1M-triangle scene (M1 baseline).
- Entity diff rebuild < 16ms for single-prim edits; full rebuild off-main with placeholder shimmer.
