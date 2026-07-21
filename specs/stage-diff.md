# Stage Diff

Contract for the editor-wide, file-oriented stage comparison: "compare two
files / before-after an edit batch" (ROADMAP, Continuous / Platform).

## Scope & relationship to `AgentMCP.StageDiff`

Two diff types exist by design; they answer different questions.

- `AgentMCP.StageDiff` — reports *what one live command changed* during an agent
  edit session, by snapshotting the same stage before and after each mutating
  tool call. Lives in `AgentMCP` because it exists to feed the agent's reasoning
  loop (docs/AGENT_MCP_PLAN.md §3).
- `USDCore.StageDelta` — the editor-wide, file-oriented comparison: point it at
  two independently-opened stages (two files, or the same file before and after
  an edit batch) and it reports the structural difference. Pure value logic in
  `USDCore` so the CLI, a future diff panel, and tests can all reuse it without
  importing each other or the agent layer.

They are deliberately not merged: one is snapshot-delta plumbing for the agent
transaction log, the other is a user-facing document comparison with a richer,
render-oriented shape (per-facet flags, per-attribute change kinds).

## Model (`StageDelta`)

Prims are matched by **absolute path** — the stable identity USD itself uses. A
rename therefore reads as one removed path + one added path, which is the
truthful structural account (the editor's `RenamePrimCommand` reparents the
subtree to a new path, so its identity genuinely changes).

`StageDelta.compute(before:after:)` produces:

- `addedPrims` / `removedPrims` — `[PrimPath]`, sorted, present in only one side.
- `changedPrims` — `[PrimChange]`, sorted by path, for prims present in both
  whose content differs (ignoring children, since child changes surface at their
  own paths). Each `PrimChange` flags exactly the facets that moved:
  `type`, `active`, `visibility`, `relationships`, `metadata`, `variants`, and a
  sorted `attributeChanges` list of `(name, .added | .removed | .modified)`.
  `changedFacets` renders these as a short label, e.g. `["type", "attributes(2)"]`.
- `changedMetadataFields` — names of the differing `StageMetadata` fields
  (`upAxis`, `metersPerUnit`, `defaultPrim`, `customLayerData`,
  `timeCodesPerSecond`, `startTimeCode`, `endTimeCode`).

`isEmpty` is true iff the two stages are structurally identical. `summaryLines()`
renders a deterministic, diff-stable report (`+`/`-`/`~` per prim, indented
attribute rows), returning `["no differences"]` for identical input so callers
always print something.

## CLI

```
openusdz diff <before.usd[z|a|c]> <after.usd[z|a|c]> [--json]
```

Opens both stages through the bridge, computes the `StageDelta`, prints the
report, and exits on the **unix-diff convention**: `0` when identical, `1` when
they differ (or on open failure). `--json` emits a machine-readable report whose
`identical` field mirrors the exit code; branch on it in pipelines.

## Harness

- `StageDeltaTests` (USDCore, 100% floor): every facet flag, every attribute
  change kind, every metadata field, ordering, and both render branches.
- `CLIDiffTests` (CLI): usage errors, the identical/differ exit-code matrix,
  metadata-change reporting, open-failure error surfacing, and the JSON shape.

## Remaining surface

The EditorUI diff panel (side-by-side tree over `StageDelta`, before/after an
edit batch) is the remaining UI work, landing on this already-verified engine
per the repo "verification harness before UI" rule.
