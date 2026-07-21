# Research — <Topic Title>

- **Slug:** `<kebab-slug>`
- **Date:** <YYYY-MM-DD>
- **Question:** <the crisp question this run answers, and the decision it drives>
- **Status:** researched | planned | superseded
- **Related topics:** <links to other research/topics/<slug>/ or "none">

## TL;DR

<2–4 sentences: what the state of the art is, and the one approach we should take.>

## Comparison set

| Tool / source | How it solves this | Cost / complexity | License | Applicability to us |
|---|---|---|---|---|
| <Blender / three.js / Filament / paper …> | <mechanism, name the file/class/paper> | <perf, code, maintenance> | <GPL / Apache-2.0 / MIT / n-a> | <fits / adapt / reject — why> |

> Cite every external claim with a URL inline. Prefer primary sources (source file,
> official docs, paper) over summaries. Note the version/date of what you looked at.

## State of the art

<What the best current approach actually is, and why. Include the math/technique
in enough depth that the plan can lean on it. Distinguish "offline/PBR-renderer
technique" from "what RealityKit can actually do for us.">

## Recommended approach for OpenUSDZEditor

<The approach we should build, in our terms (RealityKit-first, USD-native).>

### Rejected alternatives

- **<option>** — <why it lost: RealityKit can't do it / out of scope / license / cost>.

## RealityKit / constraint reconciliation

<How this reconciles with: the RealityKit renderer, ShaderGraphMaterial/Metal-overlay
limits, the arkit export profile, one-directional module deps, and the "no general
DCC" rule. Flag every gap where reality falls short of the SOTA technique.>

## License & provenance notes

<Per OSS source: license, and confirmation that we borrow ideas/math only — no
copied GPL code. Note anything that constrains how we may implement.>

## Open questions

- <anything unverified, or a decision a human must make>

## Sources

- <title> — <url> (accessed <date>)
