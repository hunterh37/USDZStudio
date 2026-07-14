# DicyaninUSDZEditor

The professional, open-source USDZ viewer and editor for macOS. See `PRD.md`, `ROADMAP.md`, and `specs/` for the full design.

## Status: Phase 0 — Foundation

- Modular SPM workspace under `Packages/` with CI-enforced one-directional dependencies (`scripts/dependency-lint.sh`)
- `USDCore` — pure Swift stage model (prim paths, prims, attributes, stage protocols)
- `USDBridge` — Python/usd-core bridge behind a swappable executor seam, with graceful degradation when no runtime is present
- `DicyaninDesignSystem` — tokens (4pt grid, palette, type scale) + inspector field logic
- Kit stubs with their spec extension-point protocols: `EditingKit`, `ValidationKit`, `ConversionKit`, `ScriptingKit`, `ViewportKit`, `EditorUI`
- App shell (`App/`) and `dicyanin-usdz` CLI (`CLI/`)

## Build & test

```sh
bash scripts/fetch-python-runtime.sh   # one-time: venv with usd-core
bash scripts/test-all.sh               # every package's tests + app build
cd App && swift run                    # launch the shell
cd CLI && swift run dicyanin-usdz info model.usdz
```

Requires Xcode 16+ / Swift 6 on macOS 14+. Without a Python runtime that can `import pxr`, the app degrades to a viewer-only state per `specs/usd-bridge.md`.
