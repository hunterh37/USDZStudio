---
description: Research other 3D-modeling/DCC/rendering software + state-of-the-art rendering patterns, then write a cited findings doc AND a precise, spec-style implementation plan that slots into OpenUSDZEditor. Usage: /research-3d <topic>
---

# /research-3d — competitor & rendering research → buildable plan

Entry point for the research system. Invoke the **`research-3d` skill** and follow
its methodology end to end for the topic in `$ARGUMENTS`.

Topic: **$ARGUMENTS**

If `$ARGUMENTS` is empty, ask for a topic (offer 2–3 candidate topics drawn from
open items in `ROADMAP.md`).

Do exactly what the skill specifies:

1. **Load context first** — `research/LOG.md`, `specs/architecture.md`, `ROADMAP.md`,
   `specs/testing.md`, and the spec closest to the topic. Don't re-research a closed
   topic; extend it.
2. **Scope** the topic to a crisp question + a slug.
3. **Compare** the 2–5 tools/papers that actually matter, from **primary sources**
   (`web_search` → `web_fetch` the real page/source/paper), verifying each
   load-bearing claim and recording each OSS license.
4. **Reconcile against RealityKit reality** and the repo's constraints (one-directional
   module deps, RealityKit-first, `arkit` export profile, no general-DCC scope creep).
5. **Write two files** in `research/topics/<slug>/`:
   `research.md` (from `research/TEMPLATE-research.md`) and
   `plan.md` (from `research/TEMPLATE-plan.md`).
6. **Close the loop** — append a row to `research/LOG.md` and cross-link related topics.

Guardrails (from the skill): never fabricate a source or API; never copy GPL code
(clean-room the approach, record the license); write only under `research/` — landing
a plan into `specs/`/`ROADMAP.md`/`Packages/` is a separate build PR that cites the plan.

At the end, report: the slug, the one-line recommendation, the target module(s), the
roadmap slot, and the two file paths — so the user can decide whether to open a build
ticket for it.
