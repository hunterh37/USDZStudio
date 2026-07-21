# Implementation Plan — <Feature Title>

- **Slug:** `<kebab-slug>` (pairs with `research.md` in this folder)
- **Date:** <YYYY-MM-DD>
- **Source research:** `./research.md`
- **Roadmap slot:** <Milestone N / Phase X — what it unblocks, what it depends on>
- **Status:** proposed | accepted | building | landed | superseded

## Summary

<1 paragraph: what we build and the user-facing outcome. Written like a specs/ entry.>

## Module targets

| Module (`Packages/*`) | Change | New dependency edges | Legal per architecture.md? |
|---|---|---|---|
| <e.g. ViewportKit> | <what changes> | <e.g. → USDCore, MeshKit (existing)> | <yes — cite the rule> |

> Confirm every edge against `specs/architecture.md`'s one-directional rules. Adding
> a package requires a `dependency-lint.sh` policy entry + an `architecture.md` update
> — call that out here if it applies. `USDCore`/`MeshKit` stay pure Swift.

## Data model / API

```swift
// Value types (Sendable), pure-function commands, actor/@MainActor as needed.
// Sketch the public surface a build agent implements against.
```

## Algorithm

<Step-by-step, with formulas / pseudo-code / edge cases. Enough that the builder does
not need to re-derive from the research. Call out numeric precision (USD floats are
32-bit), coordinate/up-axis assumptions, and failure modes.>

## RealityKit export-profile behavior

<How the feature degrades under `arkit` / `arkit-strict`. What survives a RealityKit
round-trip; what is flagged vs. dropped; how ExportGate/ComplianceChecker sees it.>

## Harness (lands in the SAME PR)

- **Invariants:** <property-based / round-trip invariants to assert>
- **Golden files:** <golden-image ΔE gate? golden .usda? which fixtures>
- **Unit tests + coverage:** <touched module → coverage floor to hold (100% / spec floor)>
- **Fuzz corpus:** <MeshKit FuzzCorpus additions, if geometry-sensitive>

## Rollout

1. <ordered steps: harness-first where the milestone requires it, then feature, then UI>

## Risks & open questions

- <risk / decision a human must make, with the tradeoff spelled out>

## Acceptance criteria

- [ ] <measurable outcome, e.g. "wireframe overlay renders on 1M-tri scene at 60fps (M1)">
- [ ] <harness green + coverage floor held>
- [ ] <degrades correctly under arkit export profile>
