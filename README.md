<div align="center">

<img src="Resources/AppIcon/icon.png" alt="OpenUSDZEditor app icon" width="128" height="128" />

# OpenUSDZEditor

**The professional, open-source USDZ viewer and editor for macOS.**

A native Mac app — SwiftUI + RealityKit + an embedded Python/`usd-core` runtime — that treats USDZ as a first-class document format: open it, inspect it, edit it, convert into it, validate it, and ship it.

<br/>

[![CI](https://github.com/hunterh37/OpenUSDZEditor/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/hunterh37/OpenUSDZEditor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen?logo=swift&logoColor=white)](https://www.swift.org/package-manager/)

[![Last commit](https://img.shields.io/github/last-commit/hunterh37/OpenUSDZEditor/main?logo=git&logoColor=white)](https://github.com/hunterh37/OpenUSDZEditor/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/hunterh37/OpenUSDZEditor?logo=github)](https://github.com/hunterh37/OpenUSDZEditor/pulse)
[![Open issues](https://img.shields.io/github/issues/hunterh37/OpenUSDZEditor?logo=github)](https://github.com/hunterh37/OpenUSDZEditor/issues)
[![Open PRs](https://img.shields.io/github/issues-pr/hunterh37/OpenUSDZEditor?logo=github)](https://github.com/hunterh37/OpenUSDZEditor/pulls)
[![Contributors](https://img.shields.io/github/contributors/hunterh37/OpenUSDZEditor?logo=github)](https://github.com/hunterh37/OpenUSDZEditor/graphs/contributors)
[![Stars](https://img.shields.io/github/stars/hunterh37/OpenUSDZEditor?style=flat&logo=github)](https://github.com/hunterh37/OpenUSDZEditor/stargazers)

[![Code size](https://img.shields.io/github/languages/code-size/hunterh37/OpenUSDZEditor?logo=github)](https://github.com/hunterh37/OpenUSDZEditor)
[![Top language](https://img.shields.io/github/languages/top/hunterh37/OpenUSDZEditor?logo=swift&logoColor=white)](https://github.com/hunterh37/OpenUSDZEditor)
[![Repo size](https://img.shields.io/github/repo-size/hunterh37/OpenUSDZEditor?logo=github)](https://github.com/hunterh37/OpenUSDZEditor)

</div>

---

## Why this exists

Apple bet the spatial ecosystem on USD, but the tooling around it is fragmented: Reality Composer Pro is closed-source and visionOS-centric, `usdview` is a developer utility with a dated Qt UI, and online converters are lossy black boxes. There is no open tool that lets you *edit* a USDZ — rename prims, swap materials, adjust transforms, fix metadata, recolor a model — without round-tripping through a full DCC like Blender.

OpenUSDZEditor is the missing piece: a beautiful, enterprise-grade native editor for the format, in the spirit of what Sketch or Nova did for their domains. Built for AR/spatial developers prepping RealityKit and QuickLook assets, 3D artists converting GLB/FBX/OBJ deliverables, e-commerce teams producing AR product visuals at volume, and pipeline engineers who want scriptable USD tooling.

## What it does

- **Viewer first, flawless.** Instant open of `.usdz`/`.usda`/`.usdc`/`.usd`, accurate PBR rendering in a RealityKit viewport (orbit/pan/dolly, framing, grid + axes), an outliner mirroring the USD prim hierarchy, read-only inspectors for transforms, prims, materials, and stage metadata, plus a stats HUD.
- **Real editing.** Non-destructive edits on the live USD stage — transforms, prim hierarchy, materials and model-wide recoloring, mesh edit mode (multi-face selection, bevel), variants, metadata — saved back to valid `.usdz`/`.usda`/`.usdc`.
- **Session restore.** Quit or crash with work open and relaunch to an offer to bring back your session — the scene, unsaved edits, the full undo/redo history (replayed from a crash-safe write-ahead log), and your view state (selection, gizmo, isolate, camera, outliner expansion, panels). Backed by a versioned envelope in Application Support; a changed-on-disk source is flagged before restore.
- **Universal conversion.** GLB/glTF (native importer), OBJ/STL/PLY/DAE (ModelIO) → USDZ through a transparent, configurable pipeline with per-stage logging, presets (ecommerce, quicklook-strict, lossless), and a batch converter with CSV/JSON reports.
- **Scriptable power.** Bundled Python + `usd-core`; heavy operations are readable scripts, and the `openusdz` CLI (`info`, `convert`, `convert-batch`) drops the same pipeline into CI and automation.
- **RealityKit-first output.** The north star: every file the app writes renders correctly in RealityKit and AR QuickLook. Exotic USD features arriving from other tools are preserved and surfaced — never silently destroyed — but tooling, validation, and defaults all drive toward a clean, portable USDZ.

See [`PRD.md`](PRD.md) for the full product spec, [`ROADMAP.md`](ROADMAP.md) for phase status, and [`specs/`](specs/) for per-module design docs.

## Open source ethos

- **MIT licensed, no strings.** The whole editor — app, packages, CLI, specs — is open. Use it in commercial pipelines, fork it, embed the packages.
- **Transparent by design.** Conversion and editing are inspectable pipelines, not black boxes: every stage logs what it did, and the Python that drives the USD stage is code you can read, copy, and extend.
- **Specs and tests as the contract.** Every module has a written spec in `specs/` and CI-enforced coverage gates — 100% on logic modules, snapshot/golden-image verification on visual ones, round-trip file-integrity invariants on every commit (see [`specs/testing.md`](specs/testing.md)).
- **Modular, contributable architecture.** Independent SPM packages with one-directional dependencies enforced by `scripts/dependency-lint.sh`, and documented extension points (importers, validators, tools) so contributions don't require understanding the whole app.
- **Data safety over cleverness.** We never silently drop or rewrite what we don't understand; unknown USD constructs are preserved and shown for inspection.

## Architecture

Modular SPM workspace under `Packages/`. Every package is built and tested on each push by the [unified CI pipeline](https://github.com/hunterh37/OpenUSDZEditor/actions/workflows/ci.yml) — a green [![CI](https://img.shields.io/github/actions/workflow/status/hunterh37/OpenUSDZEditor/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white)](https://github.com/hunterh37/OpenUSDZEditor/actions/workflows/ci.yml) badge means the whole matrix below passed its tests, coverage floors, dependency-lint, and module-governance gates.

Line-coverage floors are CI-enforced per module by [`scripts/coverage-gate.sh`](scripts/coverage-gate.sh) (mirrors [`specs/testing.md`](specs/testing.md)). `†` marks a ratchet floor pinned below its 90% spec target until the golden-image/snapshot harnesses land (tracked in ROADMAP Phase T).

| Package | Role | Coverage floor |
| --- | --- | --- |
| `USDCore` | Pure Swift stage model — prim paths, prims, attributes, stage protocols | 100% |
| `USDBridge` | Python/`usd-core` bridge behind a swappable executor seam, graceful degradation when no runtime is present | 95% |
| `MeshKit` | Mesh editing operations (topology edits, bevel, …) — plus fuzz corpus | 100% |
| `EditingKit` | Non-destructive edit operations on the stage | 100% |
| `ConversionKit` | Importers, IntermediateScene IR, texture pipeline, batch converter | 100% |
| `ValidationKit` | AR QuickLook / RealityKit compatibility validation | 100% |
| `ScriptingKit` | Python console and scripting surface | 100% |
| `AgentMCP` | MCP server exposing the kits as agent tools (never `EditorUI`) | 100% |
| `QuickLookKit` | Pure Swift render-plan logic for the QuickLook thumbnail `.appex` | 100% |
| `ViewportKit` | RealityKit viewport, camera, selection | 50% † |
| `EditorUI` | Outliner, inspectors, mesh-edit overlay, editor chrome | 34% † |
| `DicyaninDesignSystem` | Design tokens (4pt grid, palette, type scale) + core controls | 95% |

Plus the app shell (`App/`), the `openusdz` CLI (`CLI/`), and a headless editor harness (`Tools/EditorHarness`).

## Build & test

```sh
bash scripts/fetch-python-runtime.sh   # one-time: venv with usd-core
bash scripts/test-all.sh               # every package's tests + app build
bash scripts/run-app.sh [model.usdz]   # build the real .app bundle and launch it
cd App && swift run                    # quick dev run (unbundled binary)
cd CLI && swift run openusdz info model.usdz
cd CLI && swift run openusdz build recipe.json model.usda --json   # agent modeling loop (specs/build-recipes.md)
cd CLI && swift run openusdz thumbnail model.usda --frames 8 -o turn.##.png
```

Requires Xcode 16+ / Swift 6 on macOS 14+ (Apple Silicon primary, Intel best-effort). Without a Python runtime that can `import pxr`, the app degrades gracefully to a viewer-only state per [`specs/usd-bridge.md`](specs/usd-bridge.md).

### Install a build

Prebuilt **unsigned** macOS builds are attached to every tagged [Release](https://github.com/hunterh37/OpenUSDZEditor/releases) (produced by [`.github/workflows/release.yml`](.github/workflows/release.yml) via `scripts/build-release.sh`). They aren't code-signed, so clear the quarantine flag once after unzipping:

```sh
xattr -dr com.apple.quarantine OpenUSDZEditor.app
```

Prefer to build it yourself? See the full build-from-source guide in [`docs/BUILD.md`](docs/BUILD.md).

### The Xcode project

The SPM packages under `Packages/` are the source of truth for all library code, tests, and the CLI — build them with `swift build` / `swift test`. The editor *shell* additionally needs a real `.app` bundle (Info.plist, bundle id, USD document-type registration, embedded Python scripts), which a bare `swift run` executable can't produce. That bundle is generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```sh
bash scripts/generate-xcodeproj.sh     # project.yml -> OpenUSDZEditor.xcodeproj
open OpenUSDZEditor.xcodeproj       # or work in Xcode directly
bash scripts/run-app.sh [model.usdz]    # build + launch the bundle in one step
```

`project.yml` is the checked-in source of truth; the generated `.xcodeproj` is git-ignored. `cd App && swift run` still works for a fast, unbundled dev loop (it resolves the Python scripts by walking up from the repo root rather than from bundle resources).

## Status

Development has run **depth-first, not strictly phase-by-phase** — the high-value mesh-editing work was pulled forward, so the frontier is wider than a single phase number.

- **Phase 0 — Foundation:** complete.
- **Phase 1 — Viewer:** core shipped (RealityKit viewport, outliner, read-only inspectors, stats HUD). Open: IBL/HDR presets, animation transport, debug view modes, QuickLook thumbnails, release docs.
- **Phase 2 — Conversion:** mostly shipped (IntermediateScene IR, OBJ/STL/PLY/DAE, texture pipeline, conversion sheet + presets, batch converter, `openusdz` CLI with `info`/`convert`/`convert-batch`/`thumbnail`). Open: Draco decode, glTF sample-model corpus gate.
- **Phase 3 — Editing:** command layer + undo/redo, editable inspectors, rename/reparent/duplicate/group, variant switching, scale fixer, PreviewSurface material params, and Save/Save As are live. Cross-launch **session restore** (SessionKit + the crash-safe WAL; scene + unsaved edits + undo/redo + document view state) shipped. Open: viewport transform gizmos, part-level drill-down, texture replace/resize, Recolor Tier A; multi-window session restore.
- **Phase 4 — Validation & Scripting:** validation engine + ARKit ComplianceChecker + `validate`/`run` CLI + script library shipped. Open: interactive Python REPL, FBX import.
- **Phase 4.5 & Phase 5:** not started (perceptual recoloring; 1.0 polish).
- **Phase 6 — Mesh Editing:** **essentially complete, ahead of schedule** — MeshKit half-edge core, delete/merge/extrude/inset/fill/bevel, edit-mode UI, mesh-edit commands + crash journal, skinned-mesh refusal, and the 100% coverage + fuzz + golden-mesh gate. Only the v1.15 follow-ups (LoopCut, multi-segment bevel) remain.
- **Phases 7–12** (authoring spine) and **Phase T** cross-cutting coverage gates: not yet started.

So we've reached **Phase 6 on the mesh-editing track**, but Phases 1–5 still carry open items rather than being fully closed. See [`ROADMAP.md`](ROADMAP.md) for the live checklist.

## Contributing

Read the relevant spec in `specs/` before touching a module, keep the dependency direction clean (`scripts/dependency-lint.sh`), and make sure `scripts/test-all.sh` passes — coverage gates are enforced in CI. Issues and PRs welcome.

## License

[MIT](LICENSE).

---

<p align="center">
  <em>Proudly created and maintained by</em>
  <br><br>
  <a href="https://dicyaninlabs.com">
    <img src="docs/assets/dicyanin-labs-logo.png" alt="Dicyanin Labs" width="460">
  </a>
</p>
