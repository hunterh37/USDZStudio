# Bundled Scripts

Starter scripts shipped with USDZ Studio. They surface in the **Scripts**
panel (bundled section) and are the reference implementations for the scripting
model in `specs/scripting.md`.

## Two ways every script runs

Each script targets both execution modes with no change to its body, via
`_harness.py`:

1. **In-app console** — the host execs the script with injected globals `stage`,
   `selection`, `app`. Mutations are wrapped into a single undo step by the host.
2. **Headless CLI** — `openusdz run <script>.py model.usdz [--flags]`
   (or plain `python3 <script>.py model.usdz`). The harness opens the stage,
   parses flags from the script's `MANIFEST`, and saves on exit (mutating
   scripts only) unless `--dry-run`.

`_harness.py` is a private helper (leading underscore) and is hidden from the
Scripts panel.

## The script contract

```python
from _harness import begin, finish

MANIFEST = {
    "name": "Human Name",
    "description": "One line for the panel + --help.",
    "mutates": True,            # False = read-only audit
    "args": [
        {"name": "frame", "type": "float", "default": None, "help": "..."},
    ],
}

ctx = begin(globals(), MANIFEST)   # -> ScriptContext
for prim in ctx.prims():           # selection if any, else whole stage
    ...
ctx.app.log("did the thing")
finish(ctx)                        # saves headless-mutating runs; no-op in console
```

`MANIFEST.args` drives argparse headless and the console's parameter sheet.
Read-only scripts print to stdout (add a `json` bool arg for CI output);
mutating scripts get `-o/--output` and `--dry-run` for free.

## Included scripts

| Script | Mutates | Purpose |
| --- | --- | --- |
| `texture_report.py` | no | Table of textures: size, dimensions, pow2, UDIM, total footprint. |
| `quicklook_audit.py` | no | Pre-flight against AR Quick Look constraints; pass/warn/fail + exit codes. |
| `strip_animations.py` | yes | Bake time-sampled attributes to a static pose. |
| `remove_hidden_prims.py` | yes | Deactivate (or delete) invisible prims to slim the asset. |
| `batch_rename.py` | yes | Regex find/replace across prim names, collision-safe. |
| `flatten_and_export.py` | no* | Collapse composition into a self-contained .usdz/.usdc/.usda. |

\* Read-only on the source; writes only `--output`.

## Notes

- `pxr` (usd-core) is the embedded runtime; `PIL`/Pillow is optional and only
  improves texture-dimension reporting when present.
- Headless exit codes follow the CLI contract: `0` ok, `1` warnings, `2` errors.
