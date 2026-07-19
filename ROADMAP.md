# OpenUSDZEditor — Roadmap

Everything below is scoped to what native Swift + RealityKit + embedded Python/usd-core can realistically deliver. Phases gate each other; a phase ships as a tagged release.

This is a full 3D **editor**. The roadmap is organized around two spines that run the length of the project: **(A) comprehensive, CI-enforced test coverage** (Phase T, cross-cutting, always-on) and **(B) high-value USDZ editing tools** (the numbered phases, culminating in the authoring phases 7–12). Every editing capability ships behind its verification harness — invariants, golden files, round-trip `usddiff` — *before* its UI. Feature phases gate on the harness, not the demo.

---

## Phase T — Test Coverage Hardening (cross-cutting, continuous, blocking)

**Reality check:** `specs/testing.md` promises CI-enforced per-module coverage floors, but today the *only* gate wired into CI is MeshKit at 100% (`scripts/coverage-gate.sh`). `test-all.sh --coverage` runs coverage but fails nothing; every other module's floor is aspirational. This is the highest-leverage debt in the repo — untested logic is shipping green. Phase T closes it and keeps it closed. **No feature phase below is "done" until its module's gate is live and green.**

### T0 — Generalize the gate (do first, unblocks everything)
- [ ] Refactor `coverage-gate.sh` from MeshKit-only into a data-driven gate: read a `MODULES` table of `(module, floor)` and run xccov per module. Keep the annotation/manifest machinery.
- [ ] Wire the generalized gate into `ci.yml` as a required check; delete the "wired in as modules gain surface" TODO comment — the surface is here now.
- [ ] Per-module floors enforced exactly as `specs/testing.md` §Floors declares them:
  - [ ] USDCore **100%**
  - [ ] EditingKit **100%** (every command execute/undo/redo/coalesce path)
  - [ ] ValidationKit **100%** (every rule × pass/fail/edge + quick-fix round-trip)
  - [ ] ConversionKit **100%** logic (corpus integration separate)
  - [ ] ScriptingKit **100%** logic (grows with the REPL; gate lands with the console)
  - [ ] USDBridge **95%** (crash handlers annotated)
  - [ ] DicyaninDesignSystem **95%** + snapshot catalog
  - [ ] ViewportKit **90%** + golden images
  - [ ] EditorUI **90%** + snapshots + XCUITest
  - [ ] App/CLI **95%** (subcommand × exit-code matrix)
- [ ] Coverage-delta PR comment; no override label (per spec, on purpose).

### T1 — Fill the test layers the spec names but CI doesn't yet run
- [ ] **Round-trip invariants** as a CI job: open → save → `usddiff` clean, and open → edit → undo-all → save → diff clean, over the committed mini-corpus (spec §4).
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
- [x] CI: build, unit tests, asset-corpus checkout, per-module coverage gates live from day one (specs/testing.md)

**Exit:** open a USDZ, see its prim tree in a native outliner.

## Phase 1 — Best-in-class Viewer (v0.1)

- [x] RealityKit viewport: fast-path loading, orbit/pan/dolly, frame selection, grid/axes
- [ ] IBL presets + custom HDR, exposure, background modes
- [x] Outliner (search, visibility, type icons) + read-only inspector (transform, prim, material, stage tabs)
- [x] Stats HUD, bounds/AR-scale readout
- [ ] Animation playback transport
- [ ] Debug view modes: wireframe, normals, UV checker, matcap
- [ ] QuickLook thumbnail + preview extension for `.usda`
- [ ] Build-from-source docs + unsigned release builds on GitHub Releases

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
- [ ] Transform gizmos (translate/rotate/scale, snapping, coalesced undo) — edit backbone done (`TRS`↔matrix compose/decompose, `SnapSettings`, `TransformDragSession` → one coalesced `SetTransformCommand`); viewport gizmo overlay TODO
- [x] Editable inspector: transforms, prim metadata, stage metadata — `EditorDocument` (observable, `InMemoryStage` + `CommandStack`) drives editable T/R/S fields (snapped), prim rename/active/visibility, and stage up-axis/meters-per-unit/default-prim through undoable commands; `SetStageMetadataCommand` added; App menu Undo/Redo wired (material editing stays in its own slice)
- [ ] Part-level editing (flagship): drill-down/walk-up viewport selection, breadcrumb, move any child prim at any depth
- [ ] Hide (visibility) vs. Disable (active) vs. Delete part semantics with clear UI
- [ ] Isolate mode (session-layer, non-dirtying)
- [x] Rename / reparent (world-transform preserving) / duplicate / delete / group prims — command layer done: `RenamePrimCommand`, `RemovePrimCommand`, `DuplicatePrimCommand`, `ReparentPrimCommand` (4×4 inverse + `worldMatrix` compensation), `GroupPrimsCommand`; all undoable and surfaced on `EditorDocument`. Outliner UI done: ⇧-click multi-select, right-click context menu (rename/duplicate/group/move-to-root/hide-show/enable-disable/delete), inline rename, and drag-and-drop reparenting (onto a prim or empty space → root)
- [ ] Material editing (full PreviewSurface params, texture replace/resize) — params done: `PreviewSurfaceInput` catalog (all 14 UsdPreviewSurface inputs, each with declared type/range/fallback; values clamped then type-checked so an illegal edit never reaches the stage), `MaterialBinding` → `ResolvedMaterial` resolver, `SetMaterialInputCommand` (+ `RemoveAttributeCommand` for revert-to-default), both surfaced on `EditorDocument` and driven by an editable inspector Material tab (colour wells with correct sRGB→linear conversion, range sliders that commit once per drag, authored-vs-`default` badges). Resolution handles the two shapes that reach us: bindings by relationship *or* importer metadata, inherited down namespace (a deep child part resolves the material it actually renders with), and — the one that bites — inputs living on a `UsdPreviewSurface` **Shader child** in real files vs. flattened onto the Material prim by our own `USDAuthorStage`. Commands target the resolved surface prim, since authoring `inputs:*` onto the Material prim when a shader owns them is silently inert in RealityKit. Texture replace/resize still TODO — it depends on `UsdUVTexture` networks that `USDAuthorStage` doesn't author yet, so there is no texture input in the model to swap; that lands with the texture-network authoring work
- [x] `removeAttribute` mutation — closes the `SetAttributeCommand` undo gap (a newly-authored attribute could not be un-authored, so undo left a fallback-valued opinion where there had been none)
- [ ] Material binding edits + create material
- [ ] Recolor Tier A: solid-color part recolor with live preview, auto material uniquing, GeomSubset-level selection (specs/recoloring.md)
- [x] Variant set switching (undoable) — `setVariantSelection` mutation + `SetVariantSelectionCommand` (captures prior selection for undo); InMemoryStage applies it, unknown-set throws. Surfaced on `EditorDocument` (`variantSets(at:)` + `setVariantSelection(_:set:to:)`, no-op on unchanged/missing set); inspector Variant Sets picker (per-set `VariantPicker` with a clear-to-None sentinel) drives it undoably
- [x] Scale/units fixer — `ScaleFixer.command(for:targetMetersPerUnit:)` normalizes metersPerUnit and bakes a compensating `old/target` uniform scale into each root prim, preserving real-world size, as one undoable `CompositeCommand`. Surfaced on `EditorDocument.fixScale(targetMetersPerUnit:)` (no-op when already normalized); inspector Stage tab shows a "Normalize to meters" button next to Meters/unit whenever it isn't 1
- [x] Save/Save As (.usdz/.usda/.usdc) — `StageSaver` (usda pure Swift via USDASerializer, usdc/usdz converted by USD core via `stage_save.py`; failed saves never clobber the target), app File menu ⌘S/⌘⇧S, dirty tracking (`hasUnsavedChanges`), harness round-trip scenario `mesh-save-roundtrip.json` (extrude → save usdz → reopen through the bridge → re-edit). Serializer now preserves schema role types (`point3f[]`/`normal3f[]`). Flattened export still open
- [ ] Crash-safe command journal

**Exit:** real editor. Open → fix scale → swap texture → rename → export, all undoable.

## Phase 4 — Validation & Scripting (v0.4)

- [ ] ValidationRule engine + v1 rule catalog, live diagnostics drawer (engine ✓; catalog: scale/upAxis/defaultPrim/duplicate-name/mesh-topology/empty/unbound/normals ✓; drawer ✓; quick-fixes: `QuickFixRegistry` maps diagnostics → undoable `EditCommand`s for metersPerUnit (reuses ScaleFixer) and defaultPrim, wired to a per-row "Fix" button in the drawer via `EditorDocument.applyQuickFix`; duplicate-name/topology/normals/unbound intentionally have no auto-fix — see QuickFix.swift)
- [x] ComplianceChecker (ARKit profile) integration, export gating — `ValidationProfile` (named catalog + `blockingSeverity`): `.arkit` (blocks on error), `.arkitStrict` (blocks on warning); `ComplianceChecker` runs a profile → `ComplianceResult` with `isExportAllowed`/`blockingDiagnostics`/`summary` for the export path. CLI `validate` now takes `--profile NAME` (arkit|arkit-strict) with `--strict` as shorthand and conflict-guarded, gating exit code on the profile's decision. Drawer still reads the engine directly; app export flow lands with Phase 3 Save/Save As
- [ ] Python console (REPL, injected `stage`/`selection`/`app`, single-undo script runs)
- [x] Script library panel + bundled starter scripts (panel + source preview ✓; REPL execution TODO)
- [ ] CLI: `validate` ✓ (ARKit-profile catalog, most-severe-first diagnostics, `--strict` gates on warnings, exit 1 on failure); `run` ✓ (bundled-name or path resolution, `_harness` on PYTHONPATH, script flags + exit code pass through)
- [ ] FBX support via checksum-verified FBX2glTF download flow

**Exit:** the "will it work in AR?" answer machine + platform for power users.

## Phase 4.5 — Perceptual Texture Recoloring (v0.5, overlaps Phase 5 start)

- [ ] RecolorEngine: OKLab hue/chroma remap, Metal kernel + CPU reference implementation, parity-tested
- [ ] Color management: explicit sRGB/linear/P3 handling, sourceColorSpace honoring, reference-value tests
- [ ] Auto-segmentation masks (OKLab clustering, viewport-click seeding) + 2D mask refinement view
- [ ] Live textured recolor preview (double-buffered texture updates while dragging)
- [ ] `RecolorPartCommand` (textured): uniquify material + texture, undoable, round-trip tested
- [ ] Calibrated accuracy mode (inverse-render match, ΔE readout, metallic-aware)
- [ ] Console API `app.recolor(...)`, `recolor_batch.py`, CLI `recolor` subcommand
- [ ] Golden-image suite: ΔE < 2.0 gate on calibration scenes

**Exit:** recolor red leather to blue without losing the grain — live, accurate, batchable. Nothing else in the USDZ ecosystem does this.

## Phase 5 — 1.0 Polish

- [ ] Command palette (⌘K) + ActionRegistry (menu/shortcut/palette unification)
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
- [ ] LoopCut (quad-strip traversal)
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

## Continuous / Platform

- [ ] Python console REPL + `app.*` scripting parity for every command above (single-undo script runs).
- [ ] Command palette (⌘K) coverage for all authoring actions via ActionRegistry.
- [ ] USD stage **diff view** (compare two files / before-after an edit batch).
- [ ] Plugin API v2: native Swift plugin bundles for importers/panels/tools.
- [ ] visionOS companion viewer (edit on Mac, view synced over network).
