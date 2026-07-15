# DicyaninUSDZEditor — Roadmap

Everything below is scoped to what native Swift + RealityKit + embedded Python/usd-core can realistically deliver. Phases gate each other; a phase ships as a tagged release.

## Phase 0 — Foundation (weeks 1–3)

- [x] SPM workspace with all package stubs + dependency-lint CI
- [x] Document-based app shell, split-view chrome, DicyaninDesignSystem tokens + core controls
- [x] Embedded Python runtime bootstrapping (build-script fetch, load, `import pxr` smoke test) with graceful-degradation path
- [x] `BridgedStage`: open usdz/usda/usdc → prim-tree snapshot
- [x] CI: build, unit tests, asset-corpus checkout, per-module coverage gates live from day one (specs/testing.md)

**Exit:** open a USDZ, see its prim tree in a native outliner.

## Phase 1 — Best-in-class Viewer (v0.1, weeks 4–8)

- [x] RealityKit viewport: fast-path loading, orbit/pan/dolly, frame selection, grid/axes
- [ ] IBL presets + custom HDR, exposure, background modes
- [x] Outliner (search, visibility, type icons) + read-only inspector (transform, prim, material, stage tabs)
- [x] Stats HUD, bounds/AR-scale readout
- [ ] Animation playback transport
- [ ] Debug view modes: wireframe, normals, UV checker, matcap
- [ ] QuickLook thumbnail + preview extension for `.usda`
- [ ] Build-from-source docs + unsigned release builds on GitHub Releases

**Exit:** the best free USDZ viewer on macOS. Ship publicly, start collecting issues.

## Phase 2 — Conversion (v0.2, weeks 9–14)

- [x] IntermediateScene IR + `AssetImporter` protocol
- [ ] Native GLB/glTF importer — PBR ✓, KHR subset ✓, skinning + animations ✓ (UsdSkel); Draco decode still TODO
- [x] OBJ/STL/PLY/DAE via ModelIO
- [x] Texture pipeline (resize, re-encode, channel handling)
- [x] Conversion sheet UI with per-stage options + live log; presets (ecommerce, quicklook-strict, lossless) — preset model + CLI `--preset` ✓; sheet UI + live log ✓
- [x] Batch converter window + CSV/JSON reports — engine + CSV/JSON reports ✓ (BatchConverter); window UI ✓
- [ ] `dicyanin-usdz` CLI: convert ✓ (with `--preset`), convert-batch ✓ (with `--preset`), info ✓, thumbnail TODO
- [ ] glTF sample-model corpus in CI with success-rate gate

**Exit:** drop a GLB, get a validated USDZ. CLI usable in pipelines.

## Phase 3 — Editing (v0.3, weeks 15–22)

- [x] EditingKit command layer + undo/redo bridged to NSUndoManager — `CommandStack` + `InMemoryStage` + full command set (visibility/active/rename/remove/set-attr/composite) + `UndoManagerBridge`
- [ ] Transform gizmos (translate/rotate/scale, snapping, coalesced undo) — edit backbone done (`TRS`↔matrix compose/decompose, `SnapSettings`, `TransformDragSession` → one coalesced `SetTransformCommand`); viewport gizmo overlay TODO
- [x] Editable inspector: transforms, prim metadata, stage metadata — `EditorDocument` (observable, `InMemoryStage` + `CommandStack`) drives editable T/R/S fields (snapped), prim rename/active/visibility, and stage up-axis/meters-per-unit/default-prim through undoable commands; `SetStageMetadataCommand` added; App menu Undo/Redo wired (material editing stays in its own slice)
- [ ] Part-level editing (flagship): drill-down/walk-up viewport selection, breadcrumb, move any child prim at any depth
- [ ] Hide (visibility) vs. Disable (active) vs. Delete part semantics with clear UI
- [ ] Isolate mode (session-layer, non-dirtying)
- [x] Rename / reparent (world-transform preserving) / duplicate / delete / group prims — command layer done: `RenamePrimCommand`, `RemovePrimCommand`, `DuplicatePrimCommand`, `ReparentPrimCommand` (4×4 inverse + `worldMatrix` compensation), `GroupPrimsCommand`; all undoable and surfaced on `EditorDocument`. Outliner UI done: ⇧-click multi-select, right-click context menu (rename/duplicate/group/move-to-root/hide-show/enable-disable/delete), inline rename, and drag-and-drop reparenting (onto a prim or empty space → root)
- [ ] Material editing (full PreviewSurface params, texture replace/resize)
- [ ] Material binding edits + create material
- [ ] Recolor Tier A: solid-color part recolor with live preview, auto material uniquing, GeomSubset-level selection (specs/recoloring.md)
- [ ] Variant set switching (undoable)
- [ ] Scale/units fixer
- [ ] Save/Save As (.usdz/.usda/.usdc), flattened export, round-trip diff test in CI
- [ ] Crash-safe command journal

**Exit:** real editor. Open → fix scale → swap texture → rename → export, all undoable.

## Phase 4 — Validation & Scripting (v0.4, weeks 23–28)

- [ ] ValidationRule engine + v1 rule catalog, live diagnostics drawer (drawer ✓; quick-fixes TODO)
- [ ] ComplianceChecker (ARKit profile) integration, export gating
- [ ] Python console (REPL, injected `stage`/`selection`/`app`, single-undo script runs)
- [x] Script library panel + bundled starter scripts (panel + source preview ✓; REPL execution TODO)
- [ ] CLI: `validate` ✓ (ARKit-profile catalog, most-severe-first diagnostics, `--strict` gates on warnings, exit 1 on failure); `run` ✓ (bundled-name or path resolution, `_harness` on PYTHONPATH, script flags + exit code pass through)
- [ ] FBX support via checksum-verified FBX2glTF download flow

**Exit:** the "will it work in AR?" answer machine + platform for power users.

## Phase 4.5 — Perceptual Texture Recoloring (v0.5, weeks 27–31, overlaps Phase 5 start)

- [ ] RecolorEngine: OKLab hue/chroma remap, Metal kernel + CPU reference implementation, parity-tested
- [ ] Color management: explicit sRGB/linear/P3 handling, sourceColorSpace honoring, reference-value tests
- [ ] Auto-segmentation masks (OKLab clustering, viewport-click seeding) + 2D mask refinement view
- [ ] Live textured recolor preview (double-buffered texture updates while dragging)
- [ ] `RecolorPartCommand` (textured): uniquify material + texture, undoable, round-trip tested
- [ ] Calibrated accuracy mode (inverse-render match, ΔE readout, metallic-aware)
- [ ] Console API `app.recolor(...)`, `recolor_batch.py`, CLI `recolor` subcommand
- [ ] Golden-image suite: ΔE < 2.0 gate on calibration scenes

**Exit:** recolor red leather to blue without losing the grain — live, accurate, batchable. Nothing else in the USDZ ecosystem does this.

## Phase 5 — 1.0 Polish (weeks 29–34)

- [ ] Command palette (⌘K) + ActionRegistry (menu/shortcut/palette unification)
- [ ] Camera bookmarks, turntable/thumbnail rendering, "AirDrop to test on iPhone"
- [ ] Light theme, accessibility pass (VoiceOver, contrast), localization scaffolding
- [ ] Performance: 1M-tri @ 60fps target, large-stage outliner virtualization
- [ ] Docs site (DocC + user guide), CONTRIBUTING.md, good-first-issue seeding
- [ ] 1.0 release

## Phase 6 — MVP+ : Mesh Editing (v1.1, post-1.0 flagship)

Targeted mesh repair & adjustment — extrude a mounting tab, close a hole, merge vendor-mesh defects — not modeling-from-scratch (see `specs/mesh-editing.md`). Built agent-first: pure-function ops with machine-checkable invariants (Euler characteristic, manifoldness, analytic volume checks, property-based fuzzing), so correctness is provable without eyeballs.

- [ ] MeshKit package: HalfEdgeMesh (CoW value type, stable IDs), USD⇄half-edge lossless IO, invariant suite
- [ ] DeleteComponents + MergeVertices (pipeline validators)
- [ ] ExtrudeFaces + InsetFaces + FillHole
- [ ] Edit mode UI: Tab toggle, vertex/edge/face sub-modes (1/2/3), Metal component overlays, hotkeys (E/I/X/M/F), param HUD
- [ ] MeshEditCommand: snapshot undo, stage flush on commit, crash journal
- [ ] Skinned-mesh explicit refusal with diagnostic badge
- [ ] BevelEdges (single-segment, strict preconditions)
- [ ] 100%-coverage gate + fuzz corpus + golden meshes in CI

**Exit:** open a vendor USDZ, Tab into the bumper, extrude a mounting tab, fill a hole, export — all invariant-verified.

### v1.15 follow-up
- [ ] LoopCut (quad-strip traversal)
- [ ] Multi-segment bevel, skin-weight propagation investigation

## Post-1.0 Candidates (community-signal driven)

- "Strip non-RealityKit data" cleanup action + MaterialX→PreviewSurface baking quick-fix
- visionOS companion viewer (view synced over network)
- Mesh decimation UI (pymeshlab-backed), UV atlas repacking
- MeshKit extensions: solidify, edge slide, knife (candidate ops after Phase 6 lands)
- Physics authoring (RigidBody/Collider schemas) for RealityKit content
- USD stage diff view (compare two files)
- KTX2/Basis texture output, meshopt compression
- Timeline editing (trim/retime animation clips)
- Plugin API v2: native Swift plugin bundles for importers/panels

## Explicitly Out (see PRD non-goals)

Modeling/sculpting, MaterialX authoring, cloud accounts/telemetry, Windows/Linux.
