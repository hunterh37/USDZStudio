# DicyaninUSDZEditor

**The professional, open-source USDZ viewer and editor for macOS.**

A native Mac app — SwiftUI + RealityKit + an embedded Python/`usd-core` runtime — that treats USDZ as a first-class document format: open it, inspect it, edit it, convert into it, validate it, and ship it.

## Why this exists

Apple bet the spatial ecosystem on USD, but the tooling around it is fragmented: Reality Composer Pro is closed-source and visionOS-centric, `usdview` is a developer utility with a dated Qt UI, and online converters are lossy black boxes. There is no open tool that lets you *edit* a USDZ — rename prims, swap materials, adjust transforms, fix metadata, recolor a model — without round-tripping through a full DCC like Blender.

DicyaninUSDZEditor is the missing piece: a beautiful, enterprise-grade native editor for the format, in the spirit of what Sketch or Nova did for their domains. Built for AR/spatial developers prepping RealityKit and QuickLook assets, 3D artists converting GLB/FBX/OBJ deliverables, e-commerce teams producing AR product visuals at volume, and pipeline engineers who want scriptable USD tooling.

## What it does

- **Viewer first, flawless.** Instant open of `.usdz`/`.usda`/`.usdc`/`.usd`, accurate PBR rendering in a RealityKit viewport (orbit/pan/dolly, framing, grid + axes), an outliner mirroring the USD prim hierarchy, read-only inspectors for transforms, prims, materials, and stage metadata, plus a stats HUD.
- **Real editing.** Non-destructive edits on the live USD stage — transforms, prim hierarchy, materials and model-wide recoloring, mesh edit mode (multi-face selection, bevel), variants, metadata — saved back to valid `.usdz`/`.usda`/`.usdc`.
- **Universal conversion.** GLB/glTF (native importer), OBJ/STL/PLY/DAE (ModelIO) → USDZ through a transparent, configurable pipeline with per-stage logging, presets (ecommerce, quicklook-strict, lossless), and a batch converter with CSV/JSON reports.
- **Scriptable power.** Bundled Python + `usd-core`; heavy operations are readable scripts, and the `dicyanin-usdz` CLI (`info`, `convert`, `convert-batch`) drops the same pipeline into CI and automation.
- **RealityKit-first output.** The north star: every file the app writes renders correctly in RealityKit and AR QuickLook. Exotic USD features arriving from other tools are preserved and surfaced — never silently destroyed — but tooling, validation, and defaults all drive toward a clean, portable USDZ.

See `PRD.md` for the full product spec, `ROADMAP.md` for phase status, and `specs/` for per-module design docs.

## Open source ethos

- **MIT licensed, no strings.** The whole editor — app, packages, CLI, specs — is open. Use it in commercial pipelines, fork it, embed the packages.
- **Transparent by design.** Conversion and editing are inspectable pipelines, not black boxes: every stage logs what it did, and the Python that drives the USD stage is code you can read, copy, and extend.
- **Specs and tests as the contract.** Every module has a written spec in `specs/` and CI-enforced coverage gates — 100% on logic modules, snapshot/golden-image verification on visual ones, round-trip file-integrity invariants on every commit (see `specs/testing.md`).
- **Modular, contributable architecture.** Independent SPM packages with one-directional dependencies enforced by `scripts/dependency-lint.sh`, and documented extension points (importers, validators, tools) so contributions don't require understanding the whole app.
- **Data safety over cleverness.** We never silently drop or rewrite what we don't understand; unknown USD constructs are preserved and shown for inspection.

## Architecture

Modular SPM workspace under `Packages/`:

| Package | Role |
| --- | --- |
| `USDCore` | Pure Swift stage model — prim paths, prims, attributes, stage protocols |
| `USDBridge` | Python/`usd-core` bridge behind a swappable executor seam, with graceful degradation when no runtime is present |
| `MeshKit` | Mesh editing operations (topology edits, bevel, …) |
| `EditingKit` | Non-destructive edit operations on the stage |
| `ConversionKit` | Importers, IntermediateScene IR, texture pipeline, batch converter |
| `ValidationKit` | AR QuickLook / RealityKit compatibility validation |
| `ScriptingKit` | Python console and scripting surface |
| `ViewportKit` | RealityKit viewport, camera, selection |
| `EditorUI` | Outliner, inspectors, mesh-edit overlay, editor chrome |
| `DicyaninDesignSystem` | Design tokens (4pt grid, palette, type scale) + core controls |

Plus the app shell (`App/`), the `dicyanin-usdz` CLI (`CLI/`), and a headless editor harness (`Tools/EditorHarness`).

## Build & test

```sh
bash scripts/fetch-python-runtime.sh   # one-time: venv with usd-core
bash scripts/test-all.sh               # every package's tests + app build
cd App && swift run                    # launch the editor
cd CLI && swift run dicyanin-usdz info model.usdz
cd CLI && swift run dicyanin-usdz build recipe.json model.usda --json   # agent modeling loop (specs/build-recipes.md)
cd CLI && swift run dicyanin-usdz thumbnail model.usda --frames 8 -o turn.##.png
```

Requires Xcode 16+ / Swift 6 on macOS 14+ (Apple Silicon primary, Intel best-effort). Without a Python runtime that can `import pxr`, the app degrades gracefully to a viewer-only state per `specs/usd-bridge.md`.

## Status

Phase 0 (foundation) is complete. Phase 1 (best-in-class viewer) and Phase 2 (conversion) are well underway — viewport, outliner, inspectors, conversion pipeline, batch converter, and CLI are live, with mesh editing and material recoloring already landing ahead of schedule. See `ROADMAP.md` for the live checklist.

## Contributing

Read the relevant spec in `specs/` before touching a module, keep the dependency direction clean (`scripts/dependency-lint.sh`), and make sure `scripts/test-all.sh` passes — coverage gates are enforced in CI. Issues and PRs welcome.

## License

MIT.
