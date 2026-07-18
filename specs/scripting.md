# ScriptingKit Specification — Python Console, Script Library, CLI

> **Status: DESIGN — largely unimplemented.** `Packages/ScriptingKit` is
> currently a stub (~40 lines). This document is the target design, not a
> description of shipped behavior; do not plan work against it as if the
> console, script library, or `jedi` completion exist. See `ROADMAP.md` for the
> phase in which this lands. Remove this banner as sections ship.

## Why scripting is a pillar

The embedded Python runtime that powers USDBridge is exposed to users, turning the app from a tool into a platform. Pipeline engineers get the full `pxr` API against the live stage; we get community-contributed scripts as the cheapest form of extensibility.

## In-App Python Console (drawer tab)

- REPL bound to the shared interpreter with injected globals:
  - `stage` — live `Usd.Stage` of the front document
  - `selection` — list of selected prim paths
  - `app` — small facade: `app.select(paths)`, `app.frame()`, `app.run_command(...)`, `app.log(...)`
- Multiline editor (⌘↩ to run), history (↑/↓ across sessions), syntax highlighting, completion via `jedi` (bundled).
- Output pane captures stdout/stderr; exceptions render tracebacks with the offending line highlighted.
- Mutations made by scripts are wrapped: console execution opens a `CompositeCommand` boundary → **script runs are a single undo step**. (Implemented via Sdf change-block + snapshot diff to synthesize the undo.)
- Long-running scripts: cancellable (interrupt injection), progress via `app.progress(0.5, "Decimating…")`.

## Script Library (panel)

- Two sources: bundled scripts (`Resources/Python/scripts/`) and user folder (`~/Library/Application Support/OpenUSDZEditor/Scripts/`, revealed via menu).
- Script metadata in a docstring header (name, description, args schema) → auto-generated parameter sheet UI when run.

### Bundled script starters
- `batch_rename.py` — regex rename across selection
- `flatten_and_export.py`
- `bake_scale.py` — apply scale into geometry
- `texture_report.py` — table of all textures, sizes, memory
- `decimate.py` — optional `pymeshlab`-powered decimation (installed on demand via bundled pip into user site-packages)
- `screenshot_grid.py` — render turntable frames via viewport API
- `strip_animations.py`, `remove_hidden_prims.py`, `merge_usdz.py`

## Headless CLI (`openusdz`)

Separate SPM executable target linking the kits (no UI). Installed via `brew` or the app's Settings ("Install command-line tool", symlink like VS Code's `code`).

```
openusdz convert in.glb out.usdz --preset ecommerce
openusdz convert-batch ./in ./out --preset quicklook-strict --report report.csv
openusdz validate model.usdz --profile quicklook --json
openusdz info model.usdz            # tree, counts, materials, textures
openusdz run script.py model.usdz   # headless scripting
openusdz thumbnail model.usdz -o thumb.png --size 512
```

- JSON output mode on every subcommand → CI-friendly.
- Exit codes: 0 ok, 1 warnings (with `--strict`), 2 errors.

## Security Posture

- Scripts are arbitrary code by design (pro tool); we are explicit about it: user scripts folder only, no script auto-download/marketplace in v1, first-run consent dialog per new user script hash.
