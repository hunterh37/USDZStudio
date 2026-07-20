# ViewportKit Specification — RealityKit Viewport

## Scope

The center viewport: rendering, camera, selection, gizmos, environments, debug modes, playback. Built on RealityKit (`ARView` in non-AR mode / `RealityView` on macOS 15+), Metal for overlay passes.

## Rendering

- **Fast path:** unmodified USDZ loads via `Entity(contentsOf:)` — Apple's loader gives best material/skinning fidelity.
- **Edit path:** prims touched by edits are re-projected from the stage (bridge mesh extraction → `MeshDescriptor`, `PhysicallyBasedMaterial`). Per-prim entity map (`PrimPath → Entity`) enables minimal diffs.
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

## Animation Playback

- Transport bar (bottom of viewport, auto-hides when stage has no animation): play/pause, scrub, loop, playback speed, frame counter honoring stage timeCodesPerSecond. Implemented: transport state is the pure, unit-tested `PlaybackTransport` value type (advance/loop/clamp/scrub math, ViewportKit); `PlaybackController` (EditorUI, `@Observable`) drives it from a display-link tick and exposes the seconds-from-start playhead. The viewport seeks the loaded entity's `AnimationResource` to that time and holds it paused, so every transport action reduces to "show the pose at time T" (deterministic sampled poses).
- Skeletal + transform animations via RealityKit `AnimationResource` (currently the first authored clip); per-animation selection when multiple clips exist is a follow-up.

## Stats HUD (toggle, top-right)

Triangles · vertices · meshes · materials · textures + texture memory · file size · bounds dimensions in cm/m (crucial for AR scale sanity).

## Performance Targets

- 60fps orbit on 1M-triangle scene (M1 baseline).
- Entity diff rebuild < 16ms for single-prim edits; full rebuild off-main with placeholder shimmer.
