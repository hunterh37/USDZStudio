---
name: verify
description: Verify a change to this editor by driving the real app headlessly — real bridge, real document, real SwiftUI panels, rendered to PNG. Use when confirming an editor/inspector/bridge change actually works, not just that tests pass.
---

# Verifying OpenUSDZEditor

**Never launch the app on the user's screen. Never use AppleScript/System Events
to click.** This is a desktop app on the user's own machine — driving the GUI
steals their focus and types into their session. Use `editor-harness`, which
drives the same code offscreen.

## The tool

`Tools/EditorHarness` — real `BridgedStage.open` (subprocess + `stage_snapshot.py`),
real `EditorDocument`, real SwiftUI panels rendered via an offscreen `NSWindow`.
See `Tools/EditorHarness/README.md` for the scenario format and verbs.

```bash
scripts/harness.sh                    # every scenario; skips cleanly without usd-core
cd Tools/EditorHarness && swift build # then, from the repo root:
./Tools/EditorHarness/.build/debug/editor-harness dump Tests/Fixtures/material-shader.usda --select /Car/Body
./Tools/EditorHarness/.build/debug/editor-harness shot Tests/Fixtures/material-shader.usda --select /Car/Body --tab material --out /tmp/shots
```

Then **look at the PNG** with the Read tool. That's the observation; the exit
code alone isn't.

## What to do

1. **Write or extend a scenario** under `Tools/EditorHarness/Scenarios/` covering
   the change, with `expect` steps and a `shot` on either side of the edit.
   Commit it — scenarios are the regression record.
2. **Run it** (`scripts/harness.sh`), read the transcript, and Read the shots.
3. **Probe around the change**, same as any verification: an illegal value, an
   undo of a *newly authored* opinion (not just a changed one), a prim that
   inherits rather than authors, an unbound prim.

Run against a **real file through the bridge**, never a hand-built
`StageSnapshot`. The bugs worth catching here are the ones where the bridge and
the model disagree — a hand-built snapshot assumes the answer.

## Gotchas that already cost a session

- **Real files put `inputs:*` on a `Shader` child** of the Material
  (`info:id = "UsdPreviewSurface"`), not on the Material prim. Only our own
  `USDAuthorStage` flattens them. Anything material-related must go through
  `MaterialBinding.resolve` → `ResolvedMaterial.surfacePath`.
- **USD floats are 32-bit.** `0.4` in a `.usda` reads back `0.4000000059604645`.
  Compare with tolerance.
- **The bridge only surfaces what `stage_snapshot.py` emits.** If the editor
  can't see something (relationships, connections, time samples), check the
  Python payload before assuming a Swift bug.
- `ImageRenderer` can't render AppKit-backed controls; the harness uses an
  offscreen window instead. Don't "simplify" it back.

## Fixtures

`Tests/Fixtures/*.usda` — hand-written, small, readable. `material-shader.usda`
is the real-file shape: shader-backed material, plus a child mesh that inherits
its parent's binding. Add fixtures rather than growing one.

## When the harness can't reach it

The viewport (RealityKit) has no harness surface yet — `shot` renders the
inspector only. For a viewport change, say so and report what you couldn't
observe rather than launching the app.
