# research/ — 3D tooling & rendering research → buildable plans

This folder is the durable memory of a **closed-loop research system** for
OpenUSDZEditor. We study how other 3D software (open-source DCCs, engines,
renderers) and the rendering literature solve a problem, then turn each finding
into a **precise, spec-style implementation plan** that slots into this repo's
architecture — ready for a build agent to execute.

## How to run it

- **Slash command:** `/research-3d <topic>` — e.g.
  `/research-3d how Blender and F3D do wireframe-on-shaded overlays`.
- **Natural language:** "research the state of the art for GPU mesh decimation and
  how it'd fit MeshKit" triggers the same `research-3d` skill.

The skill (`.claude/skills/research-3d/SKILL.md`) holds the methodology: load repo
context → scope → compare real tools from primary sources → verify against
RealityKit reality → write the two outputs → update the log.

## Layout

```
research/
  README.md              ← you are here
  LOG.md                 ← append-only topic registry (newest first)
  TEMPLATE-research.md    ← findings template
  TEMPLATE-plan.md        ← spec-style implementation-plan template
  topics/
    <slug>/
      research.md        ← the findings (cited comparison + recommendation)
      plan.md            ← the buildable plan (modules, API, algorithm, harness)
```

## Rules of the road

- Every external claim is **cited to a primary source** (source file, official docs,
  paper). No fabricated APIs, benchmarks, or "how tool X works."
- **License hygiene:** we borrow ideas and math, never copied GPL code. Each OSS
  source's license is recorded in `research.md`.
- Every plan names **module targets** (legal per `specs/architecture.md`), a
  **harness** that lands in the same PR (the repo's 100%-coverage floor), how it
  **degrades under the `arkit` export profile**, and its **roadmap slot**.
- Research runs write **only** under `research/`. Landing a plan into `specs/` /
  `ROADMAP.md` / `Packages/` happens through a normal build PR that cites the plan —
  keeping proposals separate from the shipped contract.
- One topic = one `topics/<slug>/` folder; refine in place, supersede with a note.
