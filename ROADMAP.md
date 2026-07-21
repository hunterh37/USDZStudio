# OpenUSDZEditor — Roadmap

Everything below is scoped to what native Swift + RealityKit + embedded Python/usd-core can realistically deliver. Phases gate each other; a phase ships as a tagged release.

This is a full 3D **editor**. The roadmap is organized around two spines that run the length of the project: **(A) comprehensive, CI-enforced test coverage** (Phase T, cross-cutting, always-on) and **(B) high-value USDZ editing tools** (the numbered phases, culminating in the authoring phases 7–12). Every editing capability ships behind its verification harness — invariants, golden files, round-trip `usddiff` — *before* its UI. Feature phases gate on the harness, not the demo.

---

## Development Plan — Ordered Milestones Ahead

This section is the working plan for the next stretch of development. Milestones are **ordered by execution priority**, chosen by *(value to target users) × (verifiability today)*, not by phase number — several deliberately pull specific items forward out of their parent phases. Every milestone obeys the standing rules: each op is a pure-function command, its invariant/golden/round-trip harness lands in the **same PR** as the feature, and the module's CI coverage gate must be green before the item is "done." No item is complete until it degrades correctly under the RealityKit export profile where applicable.

### Milestone 1 — Complete the transform-gizmo family (finishes Phase 3 gizmos) — ✅ **Done**
Translate shipped; close the set so direct-manipulation editing is whole. Rotate + scale gizmos and the shared W/E/R infrastructure now shipped (see the Phase 3 "Transform gizmos" entry for detail); exit harness in place and the ViewportKit ratchet raised to its 90% spec floor.
- Rotate gizmo: world/local axis rings, angle-snap, one coalesced undoable "Rotate", multi-select about a shared pivot.
- Scale gizmo: per-axis + uniform handles, snap, coalesced "Scale", parent-space correctness matching the translate path's world→parent delta handling.
- Shared gizmo infrastructure: a mode switch (W/E/R idiom), pivot/orientation options (median vs. individual, world vs. local), and a single hit-test/drag-routing seam reused across all three.
- **Exit / harness:** parity tests against `TransformDragSession`; property-based compose/decompose round-trips; snapshot tests of gizmo layout per camera; ViewportKit ratchet floor raised.

### Milestone 2 — Land the "best free viewer" surface (finishes Phase 1, unblocks public launch) — 🚧 **Not done**
All four viewer features are built (see the Phase 1 `[x]` entries below), but the milestone is **not** complete: its exit is still gated on the distribution items and the golden-image harness. Do not mark this Done until both blockers below clear.
- ✅ Environment & lighting: IBL presets + custom HDR/EXR, exposure control, background modes.
- ✅ Debug view modes: wireframe, normals, UV checker, matcap.
- ✅ Animation playback transport: play/pause/scrub/loop over authored time-samples, driving the RealityKit viewport (the data model already carries `playbackRate`).
- ✅ QuickLook thumbnail + preview extension for `.usda` (Finder-level `.appex`, distinct from the existing CLI `usdrecord` thumbnail path).
- **Remaining blockers (why this is not Done):**
  - Build-from-source docs + unsigned release builds on GitHub Releases (Phase 1, line 124 — still `[ ]`).
  - The T1 golden-image ΔE harness itself (per-debug-mode + per-IBL-preset renders vs. reference PNGs; deterministic sampled-pose playback frames) — unbuilt (Phase T1).
- **Exit / harness:** golden-image renders per debug mode and IBL preset with a ΔE gate (this is the T1 golden-image harness — build it here); deterministic sampled-pose frames for playback; ship unsigned release builds + build-from-source docs.

### Milestone 3 — Part-level editing flagship (finishes Phase 3 differentiators) — ✅ **Done**
The headline editing capability, shipped in #16 (see the Phase 3 part-level entries for detail).
- Drill-down / walk-up viewport selection with a breadcrumb; move any child prim at any depth — `PartSelection` + `BreadcrumbBar` shipped.
- Clear Hide (visibility) vs. Disable (active) vs. Delete semantics with distinct, discoverable UI — `PartEditKind` + outliner context menu shipped.
- Isolate mode via a non-dirtying session layer — `IsolationState` view-only overlay shipped (⌘I / Esc).
- **Exit / harness:** `PartSelectionTests` selection-path units and the `part-editing.json` round-trip invariant (isolate → exit leaves the stage byte-identical, `dirty == false`) landed in the same PR. The drill-down → edit → export XCUITest smoke flow remains parked under the Phase T1 XCUITest layer, alongside the other cross-cutting UI harnesses.

### Milestone 4 — Durability & reliability (enterprise hardening) — ✅ **Done**
Make the editor safe to trust with real work. All four items shipped; see specs/editing-model.md §Dirty State & Saving and specs/testing.md §Test Layers 2/4/5 for the contracts.
- App-wide crash-safe command journal / write-ahead log over `CommandStack` with autosave-recovery on relaunch. `JournalingStage` captures each command's forward mutations *and* their computed inverses, `FileCommandJournal` is an `fsync`ed JSON-Lines WAL, and `SessionStore` handles session layout + crash detection via a live sentinel. Generalizes the mesh-edit session journal: every command is captured uniformly, with no per-command journaling code.
- Round-trip invariants promoted to a blocking CI job (`roundtrip` in `ci.yml`, `scripts/roundtrip-gate.sh`, driven by the new `openusdz roundtrip` subcommand) over the committed mini-corpus. Enforces model idempotence and edit/undo neutrality everywhere, plus an opt-in strict flattened-text diff, against an expectations table that fails on regression **and** on undeclared improvement.
- Bridge mini-corpus (`Packages/USDBridge/Tests/USDBridgeTests/Fixtures/Corpus`: cube/variants/skel/animated as usda, cube+skel packaged as usdz, plus malformed) with golden assertions. **USDBridge graduated from its 90% ratchet to its 95% spec floor** via real usd-core save-path tests — it measures 100% today.
- **Exit / harness:** `EditingKitTests/CrashRecoveryTests` writes the WAL through the real command stack, `SIGKILL`s a real child process so no cleanup runs, and restores the exact command stack (content, both stack depths, and labels) from disk alone; round-trip + corpus gates are red-on-failure in CI.

> **Known round-trip gaps recorded by the new gate** (both pre-existing and outside this milestone's scope, now enforced rather than silent): `USDASerializer` emits no `variantSet` blocks, so variant sets are dropped on save (Phase 12); and attributes the bridge surfaces as `.unsupported` — a purely time-sampled channel has no default-time value — are written as an "omitted" comment, so their values are dropped on save (Phase 10). Closing either one requires tightening `EXPECTATIONS` in `scripts/roundtrip-gate.sh`, which the gate enforces.

### Milestone 5 — Validation & scripting power tools (finishes Phase 4) — 🚧 **In progress**
- Python console REPL with injected `stage`/`selection`/`app` and single-undo script runs (the script-library panel already runs bundled/user scripts; add the interactive console). *(✅ shipped)*
- ✅ **Complete the live diagnostics quick-fix set and wire the export path through `ComplianceChecker` gating in the app UI.** The quick-fix registry now covers the empty-mesh (delete) and missing-normals (area-weighted smooth-normal synthesis, reversible via `oldAttribute: nil`) rules on top of the existing scale/defaultPrim fixes; `stage.upAxis` deliberately stays fix-less because flipping the token reinterprets geometry rather than re-orienting it (documented at the fix site). Export now runs through `ExportGate` — a pure, unit-tested policy type wrapping `ComplianceChecker` — with a profile picker (`arkit`/`arkit-strict`), a clean/advisory/blocked verdict, inline blocking + advisory diagnostics, and a deliberate "Export Anyway" override that permits but never launders the verdict. An unknown persisted profile degrades to the default rather than wedging export.
- FBX support via checksum-verified FBX2glTF download flow. *(✅ shipped)*
- **Exit / harness:** ✅ CLI `validate` gained `--json` (machine-readable report whose `exportAllowed` field mirrors the exit code) and the full {valid, invalid, warning} × {default, --json, --strict} matrix now runs as a parametrised T1 CLI suite, with JSON↔human agreement asserted diagnostic-for-diagnostic. REPL single-undo contract test lands with the console item.

### Milestone 6 — Perceptual texture recoloring (Phase 4.5, the category-defining differentiator) — 🚧 **In progress**
Nothing else in the USDZ ecosystem does this; it is the strongest reason to choose this tool. The perceptual core is built and 100%-gated; the GPU/UI surface and the in-stage textured command remain (see Phase 4.5 detail below for the item-by-item status and blockers).
- ✅ `RecolorEngine`: OKLab hue/chroma remap, parity-tested **CPU reference**, explicit sRGB/linear/P3 color management (`ConversionKit/Recolor/*`, 100%-covered). The Metal kernel is the remaining accelerator, parity-tested against this reference once built (a GPU kernel can't run under the coverage gate).
- ✅ Auto-segmentation masks (OKLab clustering + viewport-click UV seeding); ✅ calibrated ΔE readout converging < 2.0 on flat swatches. Live double-buffered textured preview (GPU) and the undoable **textured** `RecolorPartCommand` remain — the latter blocked by Phase 7 `UsdUVTexture`-network authoring (solid-color part recolor already ships in Phase 3).
- ✅ `recolor_batch.py` + CLI `recolor` subcommand. The in-app `app.recolor(...)` console facade + EditorUI panel remain (app-side wiring).
- **Exit / harness:** golden-image ΔE < 2.0 gate on calibration scenes (flat-swatch calibration assertions in CI now; full offscreen-render corpus with T1); CPU/GPU parity tests (reference shipped; GPU pending); recolor round-trip (PNG decode→recolor→encode→decode stable ✓).

### Milestone 7 — Raise the ratchets to spec (finishes Phase T, continuous)
With the golden-image, round-trip, corpus, and XCUITest harnesses now built by earlier milestones, lift ViewportKit and EditorUI from their regression ratchets toward the `specs/testing.md` floors, add the coverage-delta PR comment, and stand up the nightly perf/leaks/mutation jobs.
- **Exit:** every module in `specs/testing.md` has a live, red-on-failure gate at its spec floor; "green" means "actually tested."

> After Milestone 7 the product is at a defensible 1.0 (Phase 5 polish — command palette/⌘K + ActionRegistry, accessibility, localization, performance targets, docs site — is the packaging pass). The post-1.0 authoring spine (Phases 7–12: material/texture authoring, full mesh modeling, UV, skeleton/animation, scene/lights/physics, advanced composition) continues from there, each phase carrying its export-profile matrix and same-PR harness.

---

## Phase T — Test Coverage Hardening (cross-cutting, continuous, blocking)

**Reality check (updated):** the gate is now data-driven and enforced in CI over every module (`scripts/coverage-gate.sh` + `scripts/_coverage_measure.py`). The six logic modules plus DesignSystem and CLI meet their `specs/testing.md` floors and are enforced there. USDBridge, ViewportKit, and EditorUI sit on **ratchet floors** pinned at today's measured coverage — a regression barrier, not the spec target — because the 90%/95% spec floors assume the golden-image/snapshot/XCUITest harnesses in T1 that don't exist yet. Raise each ratchet toward its spec floor as those harnesses land; never lower it. **No feature phase below is "done" until its module's gate is live and green.**

### T0 — Generalize the gate (DONE)
- [x] Refactor `coverage-gate.sh` from MeshKit-only into a data-driven gate: reads a `MODULES` table of `(module, floor)` and runs xccov per module. Annotation/manifest machinery kept and extended with `coverage:disable`/`coverage:enable` region markers for subprocess glue.
- [x] Wire the generalized gate into `ci.yml` as a required check; removed the "wired in as modules gain surface" TODO — the surface is here now.
- [x] Spec floors enforced exactly as `specs/testing.md` §Floors declares them, where met today:
  - [x] USDCore **100%**
  - [x] MeshKit **100%**
  - [x] EditingKit **100%** (every command execute/undo/redo/coalesce path)
  - [x] ValidationKit **100%** (every rule × pass/fail/edge + quick-fix round-trip)
  - [x] ConversionKit **100%** logic (corpus integration separate)
  - [x] ScriptingKit **100%** logic
  - [x] DicyaninDesignSystem **95%** (currently 100%)
  - [x] CLI **95%** (subcommand × exit-code matrix; real-subprocess launch excluded via annotation)
  - [x] USDBridge **95%** — met in Milestone 4 (measures 100%); StageSaver save path covered by real-usd-core round-trip + mini-corpus tests
  - [ ] ViewportKit **90%** — ratchet at 37% today; needs golden-image harness (T1)
  - [ ] EditorUI **90%** — ratchet at 25% today; needs snapshot + XCUITest harnesses (T1)
- [ ] Coverage-delta PR comment; no override label (per spec, on purpose).

### T1 — Fill the test layers the spec names but CI doesn't yet run
- [x] **Round-trip invariants** as a blocking CI job (`roundtrip`): model idempotence (open → save → open is a fixed point) and edit/undo neutrality (open → edit → undo-all → save → diff clean) enforced over the committed mini-corpus, plus an opt-in strict flattened-text diff. Driven by `openusdz roundtrip` via `scripts/roundtrip-gate.sh`, with an expectations table that fails on regression and on undeclared improvement (spec §4).
- [ ] **Bridge mini-corpus**: 20 hand-built usda/usdz fixtures (variants, skels, animations, exotic schemas, malformed) with golden assertions (spec §2).
- [ ] **Conversion corpus gate**: Khronos glTF-Sample-Models in CI; success-rate gate *and* re-open-and-validate every output through ComplianceChecker (spec §3, Phase 2 exit).
- [ ] **Property-based suite** beyond MeshKit: prim-path ops, TRS compose/decompose, name sanitization (spec §5).
- [ ] **Golden-image rendering** harness for the viewport: offscreen renders vs. reference PNGs, ΔE gate, per debug-view-mode and IBL preset (spec §6).
- [ ] **Snapshot UI** catalog: every DesignSystem component state + every inspector/outliner panel config (spec §7).
- [ ] **XCUITest smoke** flows headless per-PR, full matrix nightly (spec §8).
- [ ] **CLI matrix**: every subcommand × {valid, invalid, warning} × {default, --json, --strict} (spec §9).

### T2 — Keep it honest
- [ ] Nightly: full corpus, perf benchmarks (1M-tri orbit fps, open-time), `leaks` pass on a scripted session.
- [ ] Mutation-testing spot-checks on the 100% modules — line coverage ≠ assertion quality; prove the tests actually kill mutants on EditingKit/ValidationKit/USDCore.
- [ ] Every new authoring op (phases 6–12) lands with its invariant/golden harness in the *same PR* — enforced in CONTRIBUTING.md and structurally by the gate.

**Exit:** every module in `specs/testing.md` has a live, red-on-failure gate; the four cross-cutting layers (round-trip, corpus, golden-image, XCUITest) run in CI; "green" means "actually tested."

---

## Phase 0 — Foundation

- [x] SPM workspace with all package stubs + dependency-lint CI
- [x] Document-based app shell, split-view chrome, DicyaninDesignSystem tokens + core controls
- [x] Embedded Python runtime bootstrapping (build-script fetch, load, `import pxr` smoke test) with graceful-degradation path
- [x] `BridgedStage`: open usdz/usda/usdc → prim-tree snapshot — now carries authored relationships (`material:binding`, `skel:skeleton`); before that the snapshot dropped them silently, so no opened file could resolve a mesh's material
- [x] CI: build, unit tests, asset-corpus checkout. Per-module coverage gating landed later (see Phase T), not day one — originally only MeshKit was gated.

**Exit:** open a USDZ, see its prim tree in a native outliner.

## Phase 1 — Best-in-class Viewer (v0.1)

- [x] RealityKit viewport: fast-path loading, orbit/pan/dolly, frame selection, grid/axes
- [x] IBL presets + custom HDR, exposure, background modes (pure `EnvironmentSettings` model in ViewportKit; inspector popover control strip in EditorUI; RealityKit application of resolved source/exposure/background — golden-image coverage tracked with the harness in Phase T)
- [x] Outliner (search, visibility, type icons) + read-only inspector (transform, prim, material, stage tabs)
- [x] Stats HUD, bounds/AR-scale readout
- [x] Animation playback transport (play/pause/scrub/loop/speed over authored time-samples; `PlaybackTransport` + transport bar)
- [x] Debug view modes: wireframe, normals, UV checker, matcap
- [x] QuickLook thumbnail + preview extension for `.usda` — `QuickLookKit` package (pure render-plan logic, 100% floor) drives two embedded `.appex` targets (`App/QuickLookThumbnail` `QLThumbnailProvider`, `App/QuickLookPreview` `QLPreviewingController`) registered for the Pixar USD UTIs; reuses the CLI `usdrecord` single-frame pipeline (specs/quicklook.md)
- [x] Build-from-source docs + unsigned release builds on GitHub Releases — `docs/BUILD.md` (clone → runtime → test → run, plus unsigned-build Gatekeeper steps), `scripts/build-release.sh` (unsigned `Release` `.app` packaged with `ditto` + SHA-256), and a tag-triggered `.github/workflows/release.yml` that builds and attaches the zip to the GitHub Release; README "Install a build" section links both

**Exit:** the best free USDZ viewer on macOS. Ship publicly, start collecting issues.

## Phase 2 — Conversion (v0.2)

- [x] IntermediateScene IR + `AssetImporter` protocol
- [ ] Native GLB/glTF importer — PBR ✓, KHR subset ✓, skinning + animations ✓ (UsdSkel); Draco decode still TODO
- [x] OBJ/STL/PLY/DAE via ModelIO
- [x] Texture pipeline (resize, re-encode, channel handling)
- [x] Conversion sheet UI with per-stage options + live log; presets (ecommerce, quicklook-strict, lossless) — preset model + CLI `--preset` ✓; sheet UI + live log ✓
- [x] Batch converter window + CSV/JSON reports — engine + CSV/JSON reports ✓ (BatchConverter); window UI ✓
- [x] `openusdz` CLI: convert ✓ (with `--preset`), convert-batch ✓ (with `--preset`), info ✓, thumbnail ✓
- [ ] glTF sample-model corpus in CI with success-rate gate

**Exit:** drop a GLB, get a validated USDZ. CLI usable in pipelines.

## Phase 3 — Editing (v0.3)

- [x] EditingKit command layer + undo/redo bridged to NSUndoManager — `CommandStack` + `InMemoryStage` + full command set (visibility/active/rename/remove/set-attr/composite) + `UndoManagerBridge`
- [x] Transform gizmos (translate/rotate/scale, snapping, coalesced undo) — edit backbone done (`TRS`↔matrix compose/decompose, `SnapSettings`, `TransformDragSession` → one coalesced `SetTransformCommand`). **Full gizmo family shipped**. Shared infra (`GizmoMode` W/E/R switch, `GizmoOrientation` world/local, `GizmoPivot` median/individual, `GizmoBasis`) with one hit-test/drag seam (`GizmoAxis` + `CameraRay` + `ExtrudeGizmoMath.axisParameter`) reused by all three; only the active mode's gizmo is published. **Translate**: `TranslateGizmo` X/Y/Z arrow hit-test → coalesced undoable "Move". **Rotate**: `RotateGizmo` (world/local axis-ring hit-test + signed swept-angle math, angle-snap), `EditorDocument.handleRotateGizmoDrag` composes a world-space rotation about the shared median pivot into each prim's pre-drag pose (`world' = W·T(-P)·R·T(P)`, back to parent-local) → one coalesced undoable "Rotate". **Scale**: `ScaleGizmo` (per-axis box handles + uniform centre) — per-axis scales in each prim's local frame (shear-free), uniform scales about the median pivot with parent-space correctness → coalesced "Scale". RealityKit ring/box/arrow overlays wired in `ViewportPane`; `viewportLiveTransforms` re-renders gizmo/inspector/undo without a reload. Harness: `RotateGizmoMathTests`/`ScaleGizmoMathTests`/`GizmoModeTests`/`GizmoLayoutSnapshotTests` (per-camera layout), `TransformDragSession` parity + property-based compose/decompose round-trips, `performRotateGizmoDrag`/`performScaleGizmoDrag` tooling drags; ViewportKit ratchet raised to its 90% spec floor
- [x] Editable inspector: transforms, prim metadata, stage metadata — `EditorDocument` (observable, `InMemoryStage` + `CommandStack`) drives editable T/R/S fields (snapped), prim rename/active/visibility, and stage up-axis/meters-per-unit/default-prim through undoable commands; `SetStageMetadataCommand` added; App menu Undo/Redo wired (material editing stays in its own slice)
- [x] Part-level editing (flagship): drill-down/walk-up viewport selection, breadcrumb, move any child prim at any depth — `PartSelection` (USDCore, pure): `drillDown(picked:from:)` implements the Blender/Maya "first click = whole object, repeat clicks drill one level deeper toward the picked leaf" idiom; `walkUp` climbs one level; `breadcrumb(to:in:)` resolves the ancestor trail. Surfaced on `EditorDocument` (`drillInto`, `walkUpSelection`, `breadcrumb`) and rendered by `BreadcrumbBar` over the viewport (clickable crumbs + ⌄ walk-up, ⌘↑ hotkey). Moving any child at any depth already works through the translate gizmo / `SetTransformCommand`
- [x] Hide (visibility) vs. Disable (active) vs. Delete part semantics with clear UI — `PartEditKind` (EditingKit) unifies the three confusable semantics with distinct, over-communicated copy/icons and an `isDestructive` flag; `PartEditKind.controls(for:)` yields context-aware controls (Hide↔Show, Disable↔Enable), `PartEditCommandFactory` builds the undoable command (toggle visibility / toggle active / remove-subtree). Surfaced on `EditorDocument` (`partEditControls`, `performPartEdit`) and in the outliner context menu with per-action help text
- [x] Isolate mode (session-layer, non-dirtying) — `IsolationState` (EditingKit) is a pure, view-only overlay: isolating a set shows only their lineage (ancestors + subtree), hides everything else. It authors **nothing** to the stage — the viewport drops hidden prims from its live set via the same seam structural deletes use (`viewportLivePrimPaths`), and isolate/exit bump a separate `viewRevision` so `hasUnsavedChanges` never flips. Surfaced on `EditorDocument` (`isolateSelection`/`exitIsolation`/`toggleIsolation`, ⌘I / Esc). Harness `part-editing.json` proves isolate → exit leaves the stage byte-identical and `dirty == false`
- [x] Rename / reparent (world-transform preserving) / duplicate / delete / group prims — command layer done: `RenamePrimCommand`, `RemovePrimCommand`, `DuplicatePrimCommand`, `ReparentPrimCommand` (4×4 inverse + `worldMatrix` compensation), `GroupPrimsCommand`; all undoable and surfaced on `EditorDocument`. Outliner UI done: ⇧-click multi-select, right-click context menu (rename/duplicate/group/move-to-root/hide-show/enable-disable/delete), inline rename, and drag-and-drop reparenting (onto a prim or empty space → root)
- [ ] Material editing (full PreviewSurface params, texture replace/resize) — params done: `PreviewSurfaceInput` catalog (all 14 UsdPreviewSurface inputs, each with declared type/range/fallback; values clamped then type-checked so an illegal edit never reaches the stage), `MaterialBinding` → `ResolvedMaterial` resolver, `SetMaterialInputCommand` (+ `RemoveAttributeCommand` for revert-to-default), both surfaced on `EditorDocument` and driven by an editable inspector Material tab (colour wells with correct sRGB→linear conversion, range sliders that commit once per drag, authored-vs-`default` badges). Resolution handles the two shapes that reach us: bindings by relationship *or* importer metadata, inherited down namespace (a deep child part resolves the material it actually renders with), and — the one that bites — inputs living on a `UsdPreviewSurface` **Shader child** in real files vs. flattened onto the Material prim by our own `USDAuthorStage`. Commands target the resolved surface prim, since authoring `inputs:*` onto the Material prim when a shader owns them is silently inert in RealityKit. Texture replace/resize still TODO — it depends on `UsdUVTexture` networks that `USDAuthorStage` doesn't author yet, so there is no texture input in the model to swap; that lands with the texture-network authoring work
- [x] `removeAttribute` mutation — closes the `SetAttributeCommand` undo gap (a newly-authored attribute could not be un-authored, so undo left a fallback-valued opinion where there had been none)
- [x] Material binding edits + create material — `CreateMaterialCommand` authors a `/Looks` scope + Material + `UsdPreviewSurface` shader + `material:binding` as one undoable op; surfaced via `EditorDocument.createAndBindMaterial(...)` and the Material inspector. Rebind/unbind through the resolver + `SetMaterialInputCommand`
- [ ] Recolor Tier A: solid-color part recolor with live preview, auto material uniquing, GeomSubset-level selection (specs/recoloring.md) — model-wide solid recolor shipped (`EditorDocument.recolorMaterials(...)`, single-undo, no-op guarded, tested); live per-part preview + GeomSubset-level selection remain
- [x] Variant set switching (undoable) — `setVariantSelection` mutation + `SetVariantSelectionCommand` (captures prior selection for undo); InMemoryStage applies it, unknown-set throws. Surfaced on `EditorDocument` (`variantSets(at:)` + `setVariantSelection(_:set:to:)`, no-op on unchanged/missing set); inspector Variant Sets picker (per-set `VariantPicker` with a clear-to-None sentinel) drives it undoably
- [x] Scale/units fixer — `ScaleFixer.command(for:targetMetersPerUnit:)` normalizes metersPerUnit and bakes a compensating `old/target` uniform scale into each root prim, preserving real-world size, as one undoable `CompositeCommand`. Surfaced on `EditorDocument.fixScale(targetMetersPerUnit:)` (no-op when already normalized); inspector Stage tab shows a "Normalize to meters" button next to Meters/unit whenever it isn't 1
- [x] Save/Save As (.usdz/.usda/.usdc) — `StageSaver` (usda pure Swift via USDASerializer, usdc/usdz converted by USD core via `stage_save.py`; failed saves never clobber the target), app File menu ⌘S/⌘⇧S, dirty tracking (`hasUnsavedChanges`), harness round-trip scenario `mesh-save-roundtrip.json` (extrude → save usdz → reopen through the bridge → re-edit). Serializer now preserves schema role types (`point3f[]`/`normal3f[]`). Flattened export still open
- [x] Built-in content library — `ShapeLibrary` (MeshKit) exposes parametric primitive shapes and low-poly prefab objects (19 entries across `primitives`/`prefabs` groups, lazily built via `MeshCompositing`/`Prefabs`); `LibraryPanel` browses by group·category and inserts the selection into the open document as an undoable `InsertPrimCommand` (Xform + Mesh) via `LibraryInsertion`. Tested (`ShapeLibraryTests`, `LibraryInsertionTests`, primitive tests)
- [x] Crash-safe command journal — app-wide write-ahead log over `CommandStack` (`JournalingStage` captures each command's forward mutations + computed inverses; `FileCommandJournal` is an `fsync`ed JSON-Lines WAL; `SessionStore` handles session layout and crash detection via a live sentinel) with autosave-recovery on relaunch restoring the exact undo *and* redo stacks. Generalizes the earlier `MeshEditSession` op list. Exercised by a real `SIGKILL` recovery test (Milestone 4)

**Exit:** real editor. Open → fix scale → swap texture → rename → export, all undoable.

## Phase 4 — Validation & Scripting (v0.4)

- [ ] ValidationRule engine + v1 rule catalog, live diagnostics drawer (engine ✓; catalog: scale/upAxis/defaultPrim/duplicate-name/mesh-topology/empty/unbound/normals ✓; drawer ✓; quick-fixes: `QuickFixRegistry` maps diagnostics → undoable `EditCommand`s for metersPerUnit (reuses ScaleFixer) and defaultPrim, and defaultPrim, plus upAxis (Z→Y **re-orientation** via `UpAxisFixer` — flips `upAxis` metadata and bakes a compensating −90° X rotation into each root so the model stays upright, one undoable `CompositeCommand`), wired to a per-row "Fix" button in the drawer via `EditorDocument.applyQuickFix`; duplicate-name/topology/normals/unbound intentionally have no auto-fix — see QuickFix.swift)
- [x] ComplianceChecker (ARKit profile) integration, export gating — `ValidationProfile` (named catalog + `blockingSeverity`): `.arkit` (blocks on error), `.arkitStrict` (blocks on warning); `ComplianceChecker` runs a profile → `ComplianceResult` with `isExportAllowed`/`blockingDiagnostics`/`summary` for the export path. CLI `validate` now takes `--profile NAME` (arkit|arkit-strict) with `--strict` as shorthand and conflict-guarded, gating exit code on the profile's decision. Drawer still reads the engine directly; app export flow lands with Phase 3 Save/Save As
- [x] Python console (REPL, injected `stage`/`selection`/`app`, single-undo script runs) — ScriptingKit REPL core (`ReplSession` actor: multi-line input buffering via `ReplInputClassifier` bracket/colon/backslash continuation detection, `ReplHistory` recall ring, `ReplProgram` injected-namespace program builder binding `stage`/`selection`/`app`, transcript of `ReplEntry`s; one completed submission = one interpreter run = one undoable unit, run through the same `ScriptExecuting` seam as `ScriptRunner`) now driven by the EditorUI console panel (`ConsolePanel` + `ReplController`) wired through `EditorDocument.applyConsoleEdit`, which records each stage-changing submission on the `CommandStack` via `ReplaceStageCommand`
- [x] Script library panel + bundled starter scripts (panel + source preview ✓; REPL execution TODO)
- [ ] CLI: `validate` ✓ (ARKit-profile catalog, most-severe-first diagnostics, `--strict` gates on warnings, exit 1 on failure); `run` ✓ (bundled-name or path resolution, `_harness` on PYTHONPATH, script flags + exit code pass through)
- [x] FBX support via checksum-verified FBX2glTF download flow — `FBXImporter` registered in the standard `ImporterRegistry`, backed by `scripts/fetch-fbx2gltf.sh`

**Exit:** the "will it work in AR?" answer machine + platform for power users.

## Phase 4.5 — Perceptual Texture Recoloring (v0.5, overlaps Phase 5 start)

- [x] RecolorEngine: OKLab hue/chroma remap, **CPU reference implementation**, parity-tested — `ConversionKit/Recolor/RecolorEngine.swift`: pure, deterministic OKLCh remap (snap hue → target, target mean chroma + preserved per-pixel deviation, lightness/detail preserved, optional bias + hue-variation), region statistics (coverage-weighted circular-mean hue), feathered mask blend in OKLab, and `meanDeltaE76` (CIELab). 100%-covered. The Metal live-path kernel is the remaining accelerator — it is parity-*tested against this CPU reference* once built, but is excluded here because a GPU kernel can't run under the CI coverage gate; the reference it will be measured against ships now.
- [x] Color management: explicit sRGB/linear/P3 handling, sourceColorSpace honoring, reference-value tests — `ConversionKit/Recolor/ColorManagement.swift`: sRGB transfer curves, linear-sRGB ↔ OKLab ↔ OKLCh, CIELab(D65)+ΔE*76, Display-P3 primary matrices, tagged `TextureColorSpace` decode/encode with out-of-gamut clamping, `#RRGGBB` parsing. Reference-value unit tests (mid-gray 0.214, white L*=100, ΔE white↔black=100). 100%-covered.
- [x] Auto-segmentation masks (OKLab clustering, viewport-click seeding) — `ConversionKit/Recolor/Segmentation.swift`: deterministic k-means over OKLab samples, `clusterMask(atUV:)` (click the 3D part → hit UV seeds the owning cluster) and `similarityMask(atUV:threshold:feather:)`. 100%-covered. *2D mask-refinement brush view remains (EditorUI).*
- [ ] Live textured recolor preview (double-buffered texture updates while dragging) — GPU/RealityKit path, unbuilt (needs the Metal kernel + viewport wiring).
- [ ] `RecolorPartCommand` (textured): uniquify material + texture, undoable, round-trip tested — **blocked by Phase 7**: swapping a part's albedo in-stage needs `UsdUVTexture`-network authoring in `USDAuthorStage` (the standing Phase 3 texture-replace TODO). The perceptual byte transform it would call is shipped (`RecolorPipeline`); the solid-color part recolor already ships (Phase 3 `EditorDocument.recolorMaterials`).
- [~] Calibrated accuracy mode (ΔE readout) — `RecolorPipeline` `.calibrated` mode iterates ≤3 correction passes (hue/chroma/lightness residual) and converges to ΔE < 2.0 on flat swatches, reporting `achievedDeltaE`. Inverse-render match under a calibration IBL + metallic-aware biasing remain (need offscreen RealityKit render).
- [x] Console API / `recolor_batch.py` / CLI `recolor` subcommand — `recolor_batch.py` (bundled, self-contained pure-Python OKLab remap of solid `diffuseColor` across the selection/stage — the "rebrand N SKUs" workflow; textured parts detected and skipped); `openusdz recolor <in> <out> --color --mode --source/target-space --mask-uv …` (matrix-tested). *The in-app `app.recolor(...)` console facade + EditorUI panel remain (app-side wiring).*
- [x] Golden-image / calibration ΔE < 2.0 gate — enforced as the `calibratedModeConvergesUnderDeltaE2` / `calibratedJSONReportsDeltaE` assertions in the ConversionKit + CLI suites (flat calibration swatches). Full offscreen-render golden corpus lands with the T1 golden-image harness.

**Exit:** recolor red leather to blue without losing the grain — live, accurate, batchable. Nothing else in the USDZ ecosystem does this. *(Perceptual engine + color management + segmentation + CLI + batch shipped and 100%-gated; live GPU preview, in-stage textured command (Phase 7), and the EditorUI panel remain.)*

## Phase 5 — 1.0 Polish

- [x] Command palette (⌘K) + ActionRegistry (menu/shortcut/palette unification) — `ActionRegistry`/`FuzzyMatcher`/`CommandPaletteModel` + ⌘K overlay in EditorUI; every palette action mirrors an existing menu/toolbar command (one behaviour per command). Pure ranking/selection at 100% coverage; see specs/command-palette.md (snapshot-UI harness for the overlay tracked in Phase T1)
- [ ] Camera bookmarks, turntable/thumbnail rendering, "AirDrop to test on iPhone"
- [ ] Light theme, accessibility pass (VoiceOver, contrast), localization scaffolding
- [ ] Performance: 1M-tri @ 60fps target, large-stage outliner virtualization
- [ ] Docs site (DocC + user guide), CONTRIBUTING.md, good-first-issue seeding
- [ ] 1.0 release

## Phase 6 — MVP+ : Mesh Editing (v1.1, post-1.0 flagship)

Targeted mesh repair & adjustment — extrude a mounting tab, close a hole, merge vendor-mesh defects — not modeling-from-scratch (see `specs/mesh-editing.md`). Built agent-first: pure-function ops with machine-checkable invariants (Euler characteristic, manifoldness, analytic volume checks, property-based fuzzing), so correctness is provable without eyeballs.

- [x] MeshKit package: HalfEdgeMesh (CoW value type, stable IDs), USD⇄half-edge lossless IO, invariant suite (32 tests: Euler/manifold/winding/degenerate/analytic-volume checks + property fuzzing; bridge now emits `point3f[]`/`texCoord2f[]` so opened files carry geometry)
- [x] DeleteComponents + MergeVertices (pipeline validators)
- [x] ExtrudeFaces + InsetFaces + FillHole (predicted topology deltas asserted per op)
- [x] Edit mode UI: Tab toggle, vertex/edge/face sub-modes (1/2/3), viewport tool overlay (EDIT MODE badge + always-visible active-tool indicator + E/I/X/M/F tool strip + param HUD + face-picker + inline refusal diagnostics; harness scenario `mesh-editing.json`), live viewport re-meshing (edit session and committed stage geometry replace the file-loaded model, flat-shaded with amber selection highlight), and click-to-pick faces (pure-math CameraRay/MeshPicker, unit-tested; implemented as a RealityKit overlay entity + ray-cast rather than the spec's dedicated Metal pass — revisit if per-vertex/edge dot-line rendering needs it)
- [x] MeshEditCommand: snapshot undo, stage flush on commit, crash journal (MeshEditSession op journal)
- [x] Skinned-mesh explicit refusal with diagnostic badge (MeshEditAvailability; verified through the real bridge)
- [x] BevelEdges (single-segment, strict preconditions) — uniform-width edge bevel: endpoints slide along the flanking faces' edges, the third face at each corner gains a vertex, and the edge becomes a quad (V+2/E+3/F+1 per edge, analytic-volume tested on the cube: 1 − w²/2). Strict v1 class enforced loudly: interior manifold edges, pairwise non-adjacent selection, valence-3 endpoints with closed neighborhoods, width strictly under every slide-edge length. Multi-edge bevels apply against the evolving mesh so edges sharing a flanking face compose correctly; new quads join only subsets containing both flanking faces. In the fuzz rotation; surfaced as the B tool in edit mode with a width HUD + edge-picker (viewport edge picking lands with the dedicated overlay pass)
- [x] 100%-coverage gate + fuzz corpus + golden meshes in CI — `scripts/coverage-gate.sh` holds every MeshKit source line to 100% (unreachable defensive guards carry reviewed `// coverage:disable — reason` annotations; the gate prints the exclusion manifest each run); committed fuzz corpus (`FuzzCorpus.swift`: pinned regression seeds + deterministic sweep, CI deepens to 400 iterations via `MESHKIT_FUZZ_ITERATIONS`); four committed golden .usda fixtures (bowtie fan, mixed tri/quad, UV seam across a selection border, GeomSubset borders) with pinned topology/attribute snapshots and byte-identical round-trip + untouched-UV assertions

**Exit:** open a vendor USDZ, Tab into the bumper, extrude a mounting tab, fill a hole, export — all invariant-verified.

### v1.15 follow-up
- [x] LoopCut (quad-strip traversal) — single edge-loop cut over a quad strip: walks opposite edges in both directions from a seed edge, closing on itself (a ring, e.g. around a cube) or terminating at boundaries (an open strip, e.g. across a grid). Places a midpoint per crossed rung and splits each strip quad into two. Strict v1 preconditions fail loudly (single seed edge, quads-only strip, manifold rungs, single segment); new faces inherit the split face's subsets. χ-preserving (ΔV−ΔE+ΔF=0) and volume-neutral on closed meshes (analytic-tested on the cube ring); in the fuzz rotation with a pinned regression seed. 100% MeshKit line coverage held (three reviewed defensive exclusions).
- [ ] Multi-segment bevel, skin-weight propagation investigation

# Editing-Tools Spine (post-1.0) — the authoring roadmap

The v1 editor establishes the stage-as-truth + command-layer + invariant-harness foundation. Phases 7–12 turn it into a complete USDZ authoring tool. Each phase is ordered by **(value to the target users) × (verifiability today)**. Every op is a pure-function command with a machine-checkable invariant harness landing in the same PR (Phase T rule). Every phase carries an export-profile matrix: what it authors, and what each construct degrades to under the RealityKit profile.

## Phase 7 — Material & Texture Authoring (v1.2)

Close the material story the inspector already half-owns. Highest-demand editing gap today (texture replace is a standing Phase 3 TODO).

- [ ] `UsdUVTexture` network authoring in `USDAuthorStage` — the missing model that blocks texture replace/resize/swap.
- [ ] Texture replace / resize / re-encode / channel-repack from the Material inspector, undoable, round-trip tested.
- [ ] Create/duplicate/delete PreviewSurface materials; material binding editor (assign, unbind, bind-by-GeomSubset).
- [ ] Full ORM authoring, normal-map handling, UV-transform (`st` scale/rotate/translate) nodes.
- [ ] MaterialX **read→PreviewSurface bake** quick-fix ("make this RealityKit-clean") + "strip non-RealityKit data" cleanup action.
- [ ] KTX2/Basis + meshopt on export as an advanced-profile option.
- **Harness:** material-graph round-trip diff; rendered-swatch golden images; ΔE parity on bake.

## Phase 8 — Full Mesh Modeling (v1.3) — extends Phase 6 MeshKit

Repair ops + primitives + build-recipes already ship. Grow into real modeling.

- [ ] LoopCut (quad-strip traversal); multi-segment bevel; edge slide; knife; solidify.
- [ ] Boolean ops (union/difference/intersect) with manifold-preserving invariant checks.
- [ ] Mirror, radial/grid array (as instanceable references where possible), duplicate-along-path.
- [ ] Subdivision-surface **preview** + bake-to-mesh (Catmull-Clark), decimation UI (pymeshlab-backed).
- [ ] Bridge/loft between edge loops; symmetry-aware editing.
- **Harness:** Euler/manifold/winding invariants per op; analytic-volume checks; deepened fuzz corpus; golden `.usda` per op.

## Phase 9 — UV & Attribute Authoring (v1.4)

- [ ] UV editor panel: view/select/transform UV islands over the assigned texture.
- [ ] Unwrap (angle-based/LSCM via bundled Python) + atlas repack; seam marking.
- [ ] GeomSubset authoring (create/split/merge subsets for per-face material assignment).
- [ ] Primvar/attribute editor: author/edit arbitrary primvars, vertex colors, custom attributes with type safety.
- **Harness:** UV round-trip byte-fidelity on untouched islands; overlap/utilization metrics as golden values.

## Phase 10 — Skeleton & Animation Authoring (v1.5)

Playback ships in Phase 1; this authors it.

- [ ] UsdSkel authoring: edit joint hierarchy, rest/bind transforms, re-bind skin weights (weight paint).
- [ ] Keyframe authoring on transforms + timeline editor: create/trim/retime/blend animation clips.
- [ ] Skinned-mesh editing lift — replace the Phase 6 hard refusal with weight-propagating edits.
- [ ] Blendshape/target authoring for RealityKit.
- **Harness:** joint-transform round-trip; deterministic sampled-pose golden frames; weight-sum-to-1 invariant.

## Phase 11 — Scene Authoring: Lights, Cameras, Physics (v1.6)

- [ ] Light authoring (Dome/Rect/Sphere/Distant) with RealityKit-supported params; IBL bake.
- [ ] Camera prim authoring + bookmark export as USD cameras.
- [ ] Physics: RigidBody/Collider/PhysicsScene schema authoring for RealityKit content.
- [ ] AnchoringComponent / RealityKit behavior metadata authoring for QuickLook.
- **Harness:** schema-conformance validation; ComplianceChecker gates each new construct against every profile.

## Phase 12 — Advanced USD & Composition Authoring (v2)

The comprehensive USD authoring endgame — always profile-flagged.

- [ ] Composition authoring: references/payloads/sublayers/variant-set *creation* (Phase 1–3 made these read-only).
- [ ] Variant set authoring (build a variant set from selected prim states).
- [ ] MaterialX network authoring (not just bake) behind the full-USD profile.
- [ ] Custom schema / API-schema application UI; render-purpose authoring.
- [ ] Instancing authoring (point instancers, scenegraph instancing) for volume scenes.
- **Harness:** composed-vs-flattened equivalence tests; profile-degradation snapshots (what each construct becomes under RealityKit export).

## Phase A — Agent MCP Layer (shipped; docs/AGENT_MCP_PLAN.md)

Typed, transactional, verification-gated MCP editing API over the kits
(`Packages/AgentMCP`, served by `openusdz mcp <file>`).

- [x] P1 — read + transactional mutate: JSON-RPC/stdio server, `EditSession`
      (BridgedStage → InMemoryStage → CommandStack), all §3.1/§3.2 tools,
      stable `primId` handles, synthesized diffs, undo/redo/undo_to/save,
      inline validation with off/warn/strict modes.
- [x] P2 — verify loop: `check_mesh`, 4-gate `score`, multi-view/isolated
      `render_views` (per-view cameras via usdrecord) with `statsOnly`, `raycast`.
- [x] P3 — spatial solver: `set_transform` `relativeTo` rules
      (on_top/below/left_of/right_of/in_front_of/behind/inside_center, align, gap).
- [x] P4 — assets: `import_asset` → graft → auto-`normalize_asset` → validate,
      `search_assets`, async `generate_asset`/`asset_job_status`/`fetch_asset`
      behind a pluggable provider protocol.
- [x] P5 — escape hatch + polish: manifest-validated `run_script`, MCP
      resources (`usd://scene|stats|history`), tool groups (`--groups`),
      4 workflow-recipe prompts.
- [ ] Follow-ups: in-app streamable-HTTP transport (Epic UE 5.8 direction),
      real generation providers (Meshy/Tripo) behind env keys, asset-folder
      job metadata/history, main-actor marshaling when serving a live GUI document.
- **Harness:** 100% line-coverage floor in `scripts/coverage-gate.sh`; every
  tool tested valid × invalid through full JSON-RPC dispatch; process seams
  (stdio loop, usdrecord, Python) injected and excluded with manifest reasons.

## Continuous / Platform

- [ ] Python console REPL + `app.*` scripting parity for every command above (single-undo script runs).
- [x] Command palette (⌘K) coverage for all authoring actions via ActionRegistry — `ActionRegistry` + `FuzzyMatcher` (EditorUI, pure): a value-typed, deterministically-ranked action set (subsequence fuzzy match with start/boundary/consecutive bonuses; enabled-first, score-then-title total order), driven by `CommandPaletteModel` (`@Observable @MainActor` query/results/selection) and the `CommandPaletteView` overlay (↑/↓ navigate, ↩ run, ⎋ dismiss). Each `PaletteAction` mirrors an existing menu/toolbar command so a command has one behaviour however it's invoked (File Open/Save/Save As/Export, Edit Undo/Redo, Convert/Batch/Library/Scripts/Console/Sculpt, View Validate/Environment/Agent), with `isEnabled` matching menu enablement (disabled rows appear greyed). ⌘K opens it (Convert File moved to ⇧⌘K); the App menu carries the same item. 100% coverage on `ActionRegistry`/`CommandPaletteModel`; the SwiftUI overlay is tracked with the snapshot-UI harness in Phase T1. Full authoring-action coverage extends as later phases add actions.
- [x] USD stage **diff view** (compare two files / before-after an edit batch) — `StageDiff` (USDCore, pure): `StageDiff.between(before, after)` computes a structured, value-typed diff — root-metadata field changes, added/removed prims (matched by absolute path across the flattened stage, so a rename reads as remove+add like `usddiff`), and shallow per-prim field edits (type/active/visibility plus keyed attribute/relationship/metadata/variant-set changes, each captured uniformly as a before→after `ValueChange`). `render()` gives a deterministic text report and the whole diff is `Codable`. Surfaced as `openusdz diff <before> <after> [--json]`, whose exit code follows `diff(1)` (0 identical, 1 differing, 2 usage/open error). 100% USDCore + CLI `DiffCommand` coverage. A before/after diff *panel* in EditorUI can consume the same engine (tracked with the snapshot-UI harness in Phase T1).
- [ ] Plugin API v2: native Swift plugin bundles for importers/panels/tools.
- [ ] visionOS companion viewer (edit on Mac, view synced over network).
- [x] First-launch Welcome Tour, re-triggerable from the Help menu (onboarding).
- [x] Live MCP agent-activity panel + menu-bar setup tray (observe/administer the Agent MCP server from the app).
