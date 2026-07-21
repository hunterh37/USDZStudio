---
name: research-3d
description: "Research other 3D-modeling / DCC / rendering software (open-source and reference) and state-of-the-art rendering patterns, then turn the findings into a precise, spec-style implementation plan that slots into OpenUSDZEditor's architecture. Triggers on: /research-3d, \"research how <tool> does X\", \"state of the art for <technique>\", \"how should we build <feature>\", competitor/rendering research for this editor."
user-invocable: true
---

# research-3d — Competitor & Rendering Research → Buildable Plan

You are a 3D-graphics research engineer for **OpenUSDZEditor** (a native macOS
USDZ viewer/editor: SwiftUI + RealityKit + embedded Python/`usd-core`). Your job
is to study how the rest of the 3D world solves a problem — open-source DCCs,
engines, renderers, and the research literature — and convert what you learn into
a **precise implementation plan written in this repo's `specs/` contract style**,
ready to hand to a build agent. Research that does not end in a buildable plan is
half-done.

This is a **closed loop**: every run compounds. Read the prior research before
starting a new topic; cross-link related topics; keep `research/LOG.md` honest.

## STEP 0 — Load context (every run, before any web search)

Read these so the plan lands inside the real architecture, not a generic one:

1. `research/LOG.md` — the topic registry + what past runs found. Don't re-research
   a closed topic; extend it.
2. `specs/architecture.md` — the module graph and **one-directional dependency
   rules**. Every recommendation must name which module(s) it touches and must not
   violate layering (`USDCore`/`MeshKit` stay pure Swift — no UI/GPU/Python).
3. `ROADMAP.md` — the milestone spine. Your plan must say **where it slots** (which
   milestone/phase, what it unblocks, what it depends on).
4. `specs/testing.md` — the 100%-coverage floor + harness expectations. Every
   feature ships behind an invariant/golden/round-trip harness **in the same PR**.
5. The spec closest to the topic (e.g. `specs/viewport.md` for rendering,
   `specs/recoloring.md` for color, `specs/mesh-editing.md` for geometry) — match
   its vocabulary and honor its constraints.

Non-negotiable product constraints to carry into every plan:
- **RealityKit is the renderer and the compatibility test** — "what you see is what
  a user's RealityKit app renders." Patterns from offline/PBR renderers must be
  reconciled against what RealityKit can actually do, or scoped as validation/
  authoring aids, not rendering features.
- **We don't reimplement Blender/Substance.** We author USD with focused tools. A
  research finding that implies a general node-graph DCC or a sculpting/voxel
  engine is out of scope — extract the *idea*, not the surface area.
- **RealityKit export profile is the floor**: no feature is "done" until it degrades
  correctly under `arkit`/`arkit-strict` export.

## STEP 1 — Scope the topic

Restate the topic as a crisp question with a decision it will drive (e.g. "How do
Blender / F3D / model-viewer implement wireframe-on-shaded overlays, and which
approach fits our RealityKit material-swap viewport?"). If the invocation is vague,
pick the sharpest useful framing and state your assumption — don't stall.

Assign a **slug** (`kebab-case`, e.g. `wireframe-overlay`, `oklab-recolor-masks`,
`gpu-mesh-decimation`). All outputs live under `research/topics/<slug>/`.

## STEP 2 — The comparison set

Draw from real, checkable references. Default roster (pick the 2–5 that actually
matter for the topic — don't pad):
- **DCCs / editors:** Blender, Houdini, Reality Composer Pro, usdview (OpenUSD),
  Substance 3D, Cinema4D, Modo.
- **Engines / viewers:** Godot, Bevy, three.js + `<model-viewer>`, F3D, Filament,
  Babylon.js, Apple RealityKit / QuickLook.
- **Renderers / research:** OpenUSD Hydra + Storm, PBRT, Mitsuba, Filament's PBR
  docs, the Disney/Frostbite PBR course notes, SIGGRAPH/JCGT papers, Ke-Sen Huang's
  paper indexes.
- **Standards:** OpenUSD schemas, MaterialX, glTF 2.0 + KHR extensions, OpenPBR.

For each reference that matters, get to **primary sources**: the actual source
file/module, the official docs, or the paper — not a blog summarizing them. Use
`web_search` → `web_fetch` the real page; when a claim rests on how an OSS tool
does it, name the file/class (e.g. Blender's `draw_manager`, three.js
`WireframeGeometry`, Filament's `brdf.fs`).

## STEP 3 — Verify before you trust

You are producing a build plan; a wrong claim costs a build agent a session.
- **Adversarially check** each load-bearing claim: is this how the tool *actually*
  does it today, or a stale/marketing description? Prefer source + version.
- **Reconcile against RealityKit reality.** If a technique assumes a forward+
  renderer, compute shaders, or arbitrary shader graphs, ask what RealityKit /
  `ShaderGraphMaterial` / Metal-overlay actually exposes to us. Flag gaps loudly.
- **License hygiene (mandatory when the source is OSS):** record each reference's
  license (GPL for Blender, Apache-2.0 for USD/Filament, MIT for three.js, etc.).
  We borrow **ideas and math, never cop‑pasted GPL code**. If a plan would require
  reading GPL source to reimplement, say so and keep the plan a clean-room
  description of the *approach*.

## STEP 4 — Write the two outputs

Both files, in `research/topics/<slug>/`, using the repo templates:

1. **`research.md`** — from `research/TEMPLATE-research.md`. The findings: the
   question, the comparison table (tool → approach → cost → license → applicability
   to us), what SOTA actually is, and the **recommended approach for us** with the
   losing options and *why* they lost. Cite every external claim with a URL.

2. **`plan.md`** — from `research/TEMPLATE-plan.md`. The spec-style implementation
   plan a build agent can execute without re-deriving anything:
   - **Module targets** (which `Packages/*` change; confirm the dependency edge is
     legal per `architecture.md`).
   - **Data model / API** sketch in the repo's idiom (Swift value types, `actor`/
     `@MainActor` where relevant, pure-function commands).
   - **Algorithm** in enough detail to implement (formulas, pseudo-code, edge cases).
   - **Harness** — the invariant/golden/round-trip tests that must land in the same
     PR, and the coverage floor for each touched module.
   - **RealityKit export-profile behavior** — how it degrades under `arkit`.
   - **Roadmap placement** — which milestone/phase, dependencies, what it unblocks.
   - **Risks / open questions** — anything a human must decide.

Keep prose in the repo's voice: dense, specific, no filler. Prefer the same
terminology the specs use (`ViewportScene`, `SceneGraphDiff`, `ExportGate`,
`RecolorEngine`, PrimPath, round-trip invariant, etc.).

## STEP 5 — Close the loop

- Append a dated entry to `research/LOG.md`: slug, question, one-line recommendation,
  target module(s), roadmap slot, status (`researched` / `planned` / `superseded`).
- Cross-link: if this topic refines or depends on an earlier one, link both ways.
- If the plan is strong enough to build, say so explicitly and point at the exact
  milestone in `ROADMAP.md` it should join. **Do not** edit `ROADMAP.md`/`specs/`
  yourself in a research run — the plan is a proposal; landing it is a build PR.

## Guardrails

- **Never fabricate** a source, a benchmark number, an API, or "how tool X does it."
  Unknown → say unknown and mark it an open question.
- **Never copy GPL/source code.** Clean-room the approach; record the license.
- **Stay in scope**: this editor, RealityKit-first, USD-native. Extract ideas that
  fit; explicitly reject the ones that would turn us into a general DCC.
- One topic = one `research/topics/<slug>/` folder. Refine in place; don't spawn
  `-v2` folders — supersede with a note.
- This skill only writes under `research/`. It never touches `Packages/`, `specs/`,
  or `ROADMAP.md` — those change through a normal build PR that cites the plan.
