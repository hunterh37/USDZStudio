# USDZ Studio — Product Requirements Document

**Version:** 0.1 (Draft)
**Date:** 2026-07-14
**Platform:** macOS 14+ (Apple Silicon primary, Intel best-effort)
**License:** MIT (open source)
**Language:** Swift 5.10+, SwiftUI + AppKit hybrid, RealityKit, Metal

---

## 1. Vision

USDZ Studio is the missing professional, open-source USDZ viewer and editor for macOS. Today the ecosystem is fragmented: Reality Composer Pro is closed-source and visionOS-centric, `usdview` is a developer utility with a dated Qt UI, and online converters are lossy black boxes. We build a native, enterprise-grade 3D editor that treats USDZ as a first-class document format — view it, inspect it, edit it, convert into it, and ship it.

**One-liner:** "The Sketch/Nova of USDZ — a beautiful native Mac editor for the format Apple bet the spatial ecosystem on."

## 2. Target Users

1. **AR/spatial developers** (iOS, visionOS) who need to prep assets for RealityKit and QuickLook AR — inspect scale, materials, anchoring, and fix issues without round-tripping through Blender.
2. **3D artists & tech artists** converting GLB/FBX/OBJ deliverables into validated, App Store-ready USDZ.
3. **E-commerce/enterprise teams** producing AR product visualizations at volume (batch conversion, validation, thumbnailing).
4. **Pipeline engineers** who want scriptable USD tooling (Python console, CLI mode, automation hooks).

## 3. Problem Statement

- Converting to USDZ reliably requires Apple's `usdzconvert` Python tools or Reality Converter — both unmaintained-feeling, opaque, and non-extensible.
- No open tool lets you *edit* a USDZ (rename prims, swap materials, adjust transforms, edit metadata, re-anchor) without a full DCC.
- Validation for AR QuickLook / RealityKit compatibility is trial-and-error.
- Enterprises need batch, repeatable, inspectable pipelines — GUI converters don't scale.

## 4. Product Pillars

1. **Viewer first, flawless.** Instant open, accurate PBR rendering via RealityKit, IBL environments, turntable, AR-scale ground plane, hierarchy + property inspection. If we only ever shipped the viewer, it should already be the best USDZ viewer on Mac.
2. **Real editing — the whole point.** Full non-destructive authoring on the USD stage: transforms, prim hierarchy, materials and texture networks, mesh geometry, variants, skeletons/animation, lights, cameras, physics, and metadata — saved back to valid `.usdz`/`.usda`/`.usdc`. This is a genuine 3D editor, not a viewer with a settings panel. If a USD construct can be authored, authoring it is in scope.
   **Default target, RealityKit-clean.** By default every export is validated for RealityKit and AR QuickLook compatibility, and the app steers you toward UsdPreviewSurface materials, standard geometry/skeleton schemas, and supported texture formats — because that's what most users ship. But RealityKit compatibility is a *validation baseline you can see and choose*, not a ceiling on what the editor will author. Exotic and advanced USD (MaterialX networks, custom schemas, render purposes, composition arcs) is preserved, editable, and — increasingly — authorable, always flagged against the active export profile so you know exactly what will and won't survive a RealityKit round-trip. We never destroy data silently, and we never refuse to let you author something USD supports.
3. **Universal conversion.** GLB/glTF, OBJ, FBX (via FBX2glTF), STL, PLY, DAE → USDZ, with a transparent, configurable pipeline and per-step logging. Batch mode.
4. **Scriptable power.** Bundled Python + `usd-core` runtime. Every heavy operation is a script the user can read, copy, and extend. In-app Python console against the live stage.
5. **Enterprise design & architecture.** Classic 3D editor layout (outliner / viewport / inspector / timeline-lite), restrained visual design, modular Swift packages, documented extension points. **Tested to production grade:** CI-enforced coverage gates — 100% on all logic modules, snapshot/golden-image/UI-test verification on visual modules, round-trip file-integrity invariants on every commit (see `specs/testing.md`).

## 5. Core Features (v1 scope)

### 5.1 Viewer
- Open `.usdz`, `.usda`, `.usdc`, `.usd`, `.reality` (view-only) — document-based app, tabs, recents.
- RealityKit viewport: orbit/pan/dolly camera, framing (F), orthographic presets, grid + world axes.
- IBL environment presets + custom HDR loading; exposure control; wireframe / normals / UV-checker / matcap debug view modes.
- Playback of USD animation & skeletal animation (RealityKit `AnimationResource`).
- Stats HUD: triangle/vertex counts, draw calls, texture memory, file size breakdown.

### 5.2 Inspector & Outliner
- Scene graph outliner mirroring USD prim hierarchy (search, filter by type, visibility toggles).
- Property inspector: transforms (TRS with numeric fields), prim metadata, custom attributes, applied API schemas.
- Material inspector: full `UsdPreviewSurface` parameter editing, texture slots with previews, texture replacement & re-encoding.
- Variant set browser & switcher.
- References/payloads/composition arcs visualization (read-only in v1).

### 5.3 Editing

**Flagship capability: part-level editing.** A USDZ is almost never one object — a car is body + wheels + bumpers + glass, each a child prim. The app treats every child object as a first-class editable thing:

- Full hierarchy visible in the outliner; click any part in the viewport to select it (click drills to the deepest mesh; double-click walks up to its group; ⌥-click selects the top-level assembly).
- Move/rotate/scale any child part with gizmos or numeric fields — move the wheels, raise the bumper, open the door — written as proper Xform ops on that prim.
- Per-part **disable** with two distinct, clearly-labeled semantics: *Hide* (visibility = invisible — part ships in the file, RealityKit loads it hidden, can be re-shown at runtime) vs. *Deactivate/Remove* (prim excluded from the composed stage — gone from the exported file). The UI explains which one you want.
- Delete parts outright, duplicate them (four wheels from one), reparent via drag, group parts under new Xforms (make "FrontAxle" from two wheels) — with an option to preserve world position when reparenting.
- Isolate mode: solo the selected part(s) to work on them without the rest of the car in the way.

Additional editing features:
- Transform gizmos in viewport (translate/rotate/scale) writing sparse overrides.
- Material assignment & binding edits; create new PreviewSurface materials.
- **Live part recoloring** — recolor any part (or GeomSubset) with real-time viewport feedback: solid-color parts via direct PreviewSurface edits with automatic material uniquing; textured parts via perceptual (OKLab) texture recoloring that preserves grain/weave/shading detail, with auto-segmented masks and a calibrated mode that matches the *rendered* color to a target (ΔE readout). Batchable via script/CLI. (See `specs/recoloring.md`; texture tier lands in Phase 4.5.)
- Edit stage/root metadata: `upAxis`, `metersPerUnit`, `defaultPrim`, copyright/custom layer data.
- Unit & scale fixer ("this model is 100× too big" one-click).
- Full undo/redo over an edit-command layer.

### 5.4 Conversion
- Import GLB/glTF 2.0 (native Swift parser), OBJ/STL/PLY/DAE (ModelIO), FBX (bundled FBX2glTF → glTF path).
- Conversion pipeline UI: per-step options (texture resize/format, mesh welding, draco decode, KHR extension handling), live log, warnings surfaced with fix suggestions.
- Batch converter window: folder in → folder out, presets, CSV report.
- Texture pipeline: PNG/JPG normalization, max-size clamp, ORM channel packing/unpacking.

### 5.5 Validation & Export
- AR QuickLook compatibility validator (rule-based: texture sizes, prim naming, unsupported schemas, poly budget warnings).
- `usdchecker` integration via bundled Python for spec-level validation.
- Export: `.usdz` (packaged), `.usda` (human-readable), `.usdc`, flattened vs. layered export, thumbnail PNG generation, one-click "AirDrop to iPhone to test in AR".

### 5.6 Python & Automation
- Bundled Python 3.12 + `usd-core` (pip wheel) — zero user setup.
- In-app Python console bound to the open stage (`stage` variable pre-injected).
- Script library panel: shippped scripts (decimate via pymeshlab optional, batch ops) + user scripts folder.
- Headless CLI: `openusdz convert in.glb out.usdz --preset ecommerce`.

## 6. Scope & Non-Goals

Editing is the product. The editing surface is deliberately broad and grows along the roadmap — mesh authoring, material and texture-network authoring, skeleton/animation authoring, lighting, cameras, and physics are all in scope, phased by value and verifiability (see `ROADMAP.md`). Nothing about "it's a converter/viewer" caps what the editor will let you author.

**Phasing, not exclusion.** These are sequenced later because they need their invariant/test scaffolding first, *not* because they're off-limits:

- Full mesh modeling (primitives, extrude/inset/bevel/loop-cut, booleans, mirror/array, subdivision preview, retopology-lite). Repair/adjustment ops and the primitive + build-recipe pipeline already ship; broader modeling follows in the mesh-authoring phases.
- MaterialX authoring and MaterialX→PreviewSurface baking (inspect/preserve today; author + bake on the roadmap).
- Skeleton, skin-weight, and animation authoring (playback ships first; keyframe/clip authoring follows).
- Production character rigging (IK/FK, constraints, control rigs), auto-rigging (automatic skeleton fit + weight solve), and humanoid motion retargeting with a clip/blend library. These are the late-stage animation spine (roadmap Phases 13–15, spec `specs/animation-rigging.md`); they build on the Phase 10 skeleton/keyframe authoring foundation and introduce the pure-Swift `RigKit` solver module.
- Lighting, camera, and physics (RigidBody/Collider) schema authoring for RealityKit content.

**Genuine non-goals** (these we do not intend to build):

- Windows/Linux ports (architecture shouldn't preclude it, but no effort spent).
- Cloud sync, accounts, telemetry. None. It's a local pro tool.
- A general node-graph shading DCC UI, and reimplementing the full surface area of Blender or Substance — we author USD structures directly and with focused tools.

Note: direct mesh editing *is* in scope. Live vertex editing — a component edit mode that shows the vertex/edge point cloud and lets you click-drag points (with proportional / soft-selection falloff) to deform the mesh live, scaling to millions of vertices via GPU-resident geometry — is a first-class editor feature (see `specs/mesh-editing.md` §Live vertex edit). Focused brush-style sculpt tools (grab / inflate / smooth) are a permitted future extension of the same machinery; voxel/remesh sculpting engines remain out of scope.

Everything the editor authors is measured against a selectable **export profile** (RealityKit/QuickLook by default; `lossless`/`full-USD` for advanced work), so "will this survive RealityKit?" is always answered explicitly rather than by refusing the edit.

## 7. Architecture Requirements

- **Modular Swift packages** under one workspace (see `specs/architecture.md`): `USDCore` (stage model), `USDBridge` (Python/usd-core interop), `ConversionKit`, `ViewportKit`, `EditorUI`, `ValidationKit`, `ScriptingKit`, `DicyaninDesignSystem`.
- Strict dependency direction: UI depends on kits, kits never depend on UI.
- The USD stage is the single source of truth; the RealityKit scene is a derived, observable projection.
- Command-pattern edit layer → undo/redo, scripting parity, and future collaboration for free.
- Every conversion step implements a `ConversionStage` protocol → third parties can add importers.

## 8. Design Requirements

- Classic 3D editor chrome: left outliner, center viewport, right inspector, bottom console/log drawer, top toolbar with mode switching.
- Enterprise-restrained visual language: neutral dark theme default, SF Pro, 4pt grid, no gradients-for-decoration, dense-but-legible inspector rows (see `specs/design-system.md`).
- Full keyboard-driven workflow; every menu action has a shortcut; command palette (⌘K).
- Native behaviors: document tabs, autosave-to-draft, Versions, drag-and-drop everywhere, QuickLook thumbnail/preview extension for `.usda`.

## 9. Success Metrics

- Open→first-frame < 1s for a 50MB USDZ on M-series.
- Round-trip fidelity: open + save with no edits produces semantically identical USD (validated in CI).
- Conversion parity: ≥ 95% of glTF sample-model corpus converts with correct materials.
- GitHub: 1k stars in 6 months; ≥ 10 external contributors year one (modularity is the strategy here).

## 10. Risks

| Risk | Mitigation |
|---|---|
| RealityKit can't display everything USD expresses | Stage (truth) vs. viewport (projection) split; badge unsupported features rather than hide them |
| usd-core wheel size | Fetched by build script rather than committed to the repo; zipped stdlib; no signing constraints since users compile from source |
| FBX licensing | Never link FBX SDK; use FBX2glTF binary as optional user-downloaded helper |
| Editing breadth outpaces test/invariant scaffolding | Each authoring domain ships behind its verification harness (invariants, golden files, round-trip diff) before its UI; roadmap phases gate on the harness, not the feature |
| Advanced authoring produces files RealityKit can't load | Selectable export profiles + always-on compatibility validation; the app flags non-portable constructs rather than forbidding them |

## 11. Document Map

- `specs/architecture.md` — module layout, dependency rules, data flow
- `specs/usd-bridge.md` — Python/usd-core embedding & the Swift↔USD boundary
- `specs/viewport.md` — RealityKit viewport, camera, gizmos, debug modes
- `specs/conversion-pipeline.md` — importer protocol, GLB→USDZ pipeline, batch
- `specs/editor-ui.md` — panel layout, outliner, inspector, command palette
- `specs/editing-model.md` — command pattern, undo, stage mutation rules
- `specs/validation.md` — AR QuickLook rules, usdchecker integration
- `specs/scripting.md` — Python console, script library, CLI
- `specs/recoloring.md` — part-level live recolor, perceptual texture recoloring
- `specs/mesh-editing.md` — MeshKit, component-level ops (MVP+ phase)
- `specs/animation-rigging.md` — RigKit, skeleton/rig/anim data model, IK/FK + constraint solvers, auto-rig, humanoid retargeting (Phases 10, 13–15)
- `specs/testing.md` — coverage gates, test layers, CI pipeline
- `specs/design-system.md` — DicyaninDesignSystem tokens & components
- `ROADMAP.md` — phased delivery plan
