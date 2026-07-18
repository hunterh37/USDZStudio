# Build Recipes Specification — Agent-Driven Low-Poly Modeling

## Why

`specs/mesh-editing.md` scopes MeshKit to repair. Recipes extend it to
build-from-stock without changing that scope: a **declarative JSON plan**
(primitives + op chain + flat materials) that a coding agent emits, executes
headlessly, and iterates on against machine-checkable feedback. The agent
loop:

```
agent writes recipe.json
  → openusdz build recipe.json out.usda --json     # execute + report
  → openusdz validate out.usda                     # compliance gate
  → openusdz thumbnail out.usda --frames 8 -o t.##.png   # observe
  → agent reads the report + renders, edits the recipe, repeats
```

Every stage is deterministic and exits non-zero with a typed, coordinates-
carrying diagnostic (`part 'Body' step 2: …`) on failure.

## Pieces

- **`MeshKit/Primitives`** — box (per-axis segments, welded lattice), plane,
  cylinder, cone, uvSphere. Contract (enforced by `PrimitiveTests`): healthy
  invariants, outward winding (`signedVolume > 0`), χ = 2 when closed,
  closed-form V/E/F counts, analytic volume where one exists.
- **`MeshKit/Ops/TransformComponents`** — scale→rotate→translate of a
  selection about a pivot (`selectionCentroid` | `origin` | point). Zero
  topology delta; degenerate results rejected by the shared invariant check.
- **`MeshKit/Recipe/*`** — schema (`ModelRecipe`), selector resolution,
  engine, and the `.usda` writer. The writer authors the real-file material
  shape: `UsdPreviewSurface` shader as a *child* of the Material, bindings
  via `MaterialBindingAPI`, subsets in the `materialBind` family.
- **CLI `build`** — executes a recipe; `--json` emits per-step topology
  deltas, bounds, closedness, and volume per part.
- **CLI `thumbnail`** — renders via `usdrecord` (located beside the venv
  Python; `DICYANIN_USDRECORD` override). `--frames N` authors a hidden
  turntable wrapper stage (animated `rotateY` around a reference) so
  usdrecord's auto-framing camera orbits the model.

## Selectors

Exactly one source per step, resolved against the mesh state *at that step*
(export-order indices): `all`, `faces: [i]`, `vertices: [i]`,
`edges: [[a,b]]`, `facing: [x,y,z]` (+ `minDot`, default 0.9), `within:
{min,max}` (standalone or refining `all`/`facing`), `boundary`, and `last`
(previous step's result — the idiom for "the cap I just made").

## Ops

`extrude` (distance, optional axis), `inset` (fraction), `bevel` (width),
`translate`/`rotate`/`scale`/`transform` (+ pivot), `merge` (threshold XOR
targetVertex), `delete`, `fillHole` (one loop per call; chain for several),
`assignMaterial` (tags a subset named after the material → bound GeomSubset),
`tagSubset` (unbound tag). Unknown ops/params fail listing the known set.

## Invariants and testing

Each op's own `OpSupport.verify` runs per step; the engine re-checks the
final mesh per part. MeshKit stays in the 100%-coverage tier — recipe code
included. CLI behavior is tested through injected read/write/spawn seams
(`BuildCommandTests`, `ThumbnailCommandTests`); no test touches Python or a
renderer.
