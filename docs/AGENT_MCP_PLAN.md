# Agent MCP Layer — Design Plan

> A typed, transactional, verification-gated editing API over a queryable USD scene graph.
> Goal: let a coding agent build 3D scenes and high-fidelity objects reliably, with geometric
> ground truth in the loop — not by emitting raw scripts and hoping.

## 0. Prior art (surveyed 2026-07)

What the ecosystem does today, and where this plan differs:

- **BlenderMCP** (ahujasid, ~22k★) — stdio MCP ⇄ TCP socket ⇄ in-app addon; a few typed verbs plus an `execute_blender_code` hole. Killer feature is **asset integration** (PolyHaven, Hyper3D Rodin, Hunyuan3D, Sketchfab): agents compose real assets instead of hallucinating geometry. Weaknesses users report: bpy API hallucination, no undo/transactions, bridge timeouts on big scripts, organic modeling effectively out of reach.
- **fxhoudinimcp** (Houdini) — 179 typed tools over Houdini's built-in `hwebserver`; VEX **pre-execution validation**; rides native undo. **dcc-mcp-maya** — 76 tools in staged "skill packages" with **progressive tool loading** to fight context bloat; thread-affinity metadata; scene exposed as MCP **resources**.
- **CoplayDev unity-mcp** — ~48 typed tools + 25 read-only MCP resources; per-session tool-group activation; **test-runner and compile loops as tools**. **Epic's official UE 5.8 MCP** — in-process streamable-HTTP server (no sidecar), automation tests as first-class verbs: the direction of travel for transports.
- **CAD servers** (rhinomcp, build123d-mcp, cadquery-mcp) — the best verification culture: **measure the B-rep, don't trust the script** (volume/bbox/topology/feature-detection readback), explicit PASS/FAIL `verify` tools, schema-validation strictness modes (off/warn/strict), graduated escape hatches with API-doc lookup. rhinomcp is nearly alone in exposing undo/redo.
- **cinema4d-mcp** — **GUID-based object registry**: creations return stable IDs, later calls accept them, killing name-collision ambiguity across long agent sessions.
- **NVIDIA kit-usd-agents / RTX Remix MCP** — separates knowledge-retrieval MCPs (USD API docs/snippets) from scene mutation; Remix ships **MCP Prompts as workflow recipes** which its docs credit with reducing multi-step errors. **openusd-mcp** (daslabhq) — the only USD-file MCP: 8 read-heavy tools, *no transactions, no diffs, no undo*.
- **Research** — BlenderGym (CVPR'25): spend inference budget on **verification, not just generation**. SceneCraft: declarative **constraints beat raw coordinate emission** (88.9 vs 5.6 constraint-pass). LLMR: a compact **scene summarizer** cut error 4×. EZBlender: top failure modes are invalid names/out-of-range params — caught cheapest by a **pre-execution validator**.

**Positioning:** nobody ships a typed, *transactional*, verification-gated MCP over USD. Undo/diffs are the ecosystem's weakest area and our `CommandStack` gives them for free; validation is our second differentiator via `ValidationKit`. Apple has no agent API for USD. This plan already aligned with the strongest published findings (typed verbs, constraint placement, closed-loop scoring); the adjustments below fold in the remaining proven ideas.

## 1. Core principles

1. **Typed verbs, not a code hole.** Every common operation is a first-class tool with typed params and a structured return. Raw scripting exists only as a single, sandboxed escape hatch.
2. **Everything is a transaction.** All mutations go through `CommandStack`. Each agent action = one `EditCommand` = one undoable step with a diff the agent can reason about, branch from, and roll back.
3. **Structured state over screenshots.** The agent reads the USD stage as typed hierarchy (cheap, exact) and uses renders only for visual judgment.
4. **Close the loop with validation.** After every mutation the agent gets geometric truth (manifold, normals, scale, schema, interpenetration) plus a score against intent, and iterates until a gate passes.
5. **Spatial intent, not raw coordinates.** The agent expresses relationships ("B on top of A, centered"); the engine solves the transform deterministically.

## 2. Architecture

```
Agent (MCP client)
      │  JSON-RPC (stdio)
      ▼
MCP Server  ──►  EditSession (owns CommandStack + BridgedStage)
  tools:                 │
   read   ──────────────►│  USDStageProtocol  (allPrims / prim(at:) / prims(named:))
   mutate ──────────────►│  CommandStack.run(any EditCommand)  → verb string
   verify ──────────────►│  ValidationEngine / ComplianceChecker / MeshInvariants
   render ──────────────►│  MeshFlattener → offscreen render (multi-view)
   asset  ──────────────►│  ImporterRegistry / ConversionPipeline
   script ──────────────►│  ScriptRunner  (sandboxed escape hatch)
```

The MCP server is a thin adapter. It holds one `EditSession` per open document, translates
each tool call into an existing `EditCommand` (or a read/validate call), and serializes the
result. No new editing logic lives in the server — it maps 1:1 onto shipped `*Kit` APIs.

## 3. Tool surface

Every mutating tool returns `{ verb, diff, validation, undoToken, primIds }`. `verb` is the string
from `CommandStack.run`. `diff` is the `StageMutation` set. `validation` is the post-op report
(§3.3). `undoToken` lets the agent roll back a specific step.

**Stable prim handles.** `primIds` maps affected paths to session-stable IDs (cinema4d-mcp's
GUID-registry idea). USD prim paths break on rename/reparent — a long agent session that renames
`/Table` mid-build invalidates every path in its context. All tools accept either a path or a
`primId`; the server keeps the id→path mapping current across `RenamePrimCommand` /
`ReparentPrimCommand`.

**Parameter pre-validation.** Every tool validates inputs *before* touching the stage — prim
paths/ids must resolve, enums must match, values must be in range — and fails with a structured,
correctable error. Invalid names and out-of-range params are the top observed agent failure mode
(EZBlender); catching them pre-execution is far cheaper than a debug cycle.

### 3.1 Read (no mutation, cheap)

| Tool | Backing API | Returns |
|---|---|---|
| `query_scene(filter?)` | `USDStageProtocol.allPrims()` / `prims(named:)` | typed prim hierarchy: path, type, xform, material binding, bbox |
| `get_prim(path)` | `prim(at: PrimPath)` | prim + attributes (`attribute(named:)`), children |
| `scene_stats()` | `SceneStats` | prim/mesh/tri counts, bounds, up-axis, metersPerUnit |
| `list_variants(path)` | `Prim.variantSets` (`VariantSet`) | variant sets + current selections |
| `describe_scene()` | composite over the above | one-call compact summary: hierarchy outline + bounds + material bindings + xforms, token-budgeted |

`describe_scene` is the LLMR "Scene Analyzer" lesson: a single compact, typed snapshot beats
prim-by-prim traversal and lets a fresh agent context re-orient in one call. The same payloads
are additionally exposed as read-only **MCP resources** (`usd://scene`, `usd://stats`,
`usd://selection`) so clients that support resources get state readback without burning tool calls.

### 3.2 Mutate (transactional — each maps to an `EditCommand`)

| Tool | `EditCommand` |
|---|---|
| `create_prim(parent, name, type)` | `InsertPrimCommand` |
| `remove_prim(path)` | `RemovePrimCommand` |
| `rename_prim(path, name)` | `RenamePrimCommand` |
| `reparent_prim(path, newParent)` | `ReparentPrimCommand` |
| `duplicate_prim(path)` | `DuplicatePrimCommand` |
| `group_prims(paths, name)` | `GroupPrimsCommand` |
| `set_active(path, bool)` | `SetActiveCommand` |
| `set_attribute(path, name, value)` | `SetAttributeCommand` |
| `remove_attribute(path, name)` | `RemoveAttributeCommand` |
| `set_transform(path, trs)` | `SetTransformCommand` |
| `set_variant(path, set, sel)` | `SetVariantSelectionCommand` |
| `create_material(path, params)` | `CreateMaterialCommand` |
| `edit_mesh(path, ops)` | `MeshEditCommand` (via `MeshEditSession`) |
| `batch(ops[])` | `CompositeCommand` (atomic multi-op, one undo step) |

`edit_mesh` accepts a list of `MeshOp` (protocol) — extrude, primitive construction
(`Primitives`), etc. — each returning a `MeshOpResult` with a `TopologyDelta` so the agent
sees exactly what changed (verts/edges/faces added/removed).

### 3.3 Verify (the differentiator — geometric ground truth)

| Tool | Backing API | Returns |
|---|---|---|
| `validate(profile?)` | `ValidationEngine.validate(stage)` | `ValidationReport`: `[Diagnostic]` + counts by `DiagnosticSeverity` |
| `check_compliance(profile)` | `ComplianceChecker.check(stage)` | `ComplianceResult` against a `ValidationProfile` |
| `check_mesh(path)` | `MeshInvariants` | manifold/watertight/normals/degenerate-face `Violation`s |
| `score(intent)` | render + validation composite | 0–1 fidelity score + failing gates (see §4) |

Validation is invoked automatically after every mutate call and returned inline, with a
configurable **strictness mode** (rhinomcp's off/warn/strict): `warn` returns diagnostics
inline but commits; `strict` rejects the mutation if it introduces `.error` diagnostics;
`off` for bulk phases the agent will validate at the end. `score` is the explicit
closed-loop gate for autonomous multi-step building.

### 3.4 Render (visual judgment only)

| Tool | Backing API |
|---|---|
| `render_views(paths?, views?, angles?)` | `MeshFlattener.Buffers` → offscreen render, default `[front, side, top, persp]`; `angles` adds arbitrary auto-framed orbit shots `{azimuth, elevation, distance}` |
| `find_best_view(paths?, count?)` | samples the orbit sphere, ranks angles by projected silhouette footprint — no render; feed results into `render_views(angles:)` |
| `raycast(origin, dir)` | `CameraRay.Ray` — pick/hit-test for spatial checks |

Multi-view by default: a single viewport grab is insufficient for fidelity judgment.
`render_views(paths:)` can isolate a subtree (isolated-object render, à la IvanMurzak's
Godot MCP) so the agent judges one asset without scene clutter. Beyond the four canonical
views, `angles` lets the agent orbit to any `{azimuth, elevation}` (auto-framed so the
subject stays in shot), and `find_best_view` picks the most revealing angles up front —
a cheap geometry pass so the agent spends render budget only on informative captures. Renders are **opt-in, never
automatic**: geometric readback (§3.3) is the cheap default truth signal, and a
`stats_only` mode returns bbox/tri-count/material summary in place of pixels when the
agent only needs confirmation, not judgment (freecad-mcp's token-saving toggle).

### 3.5 Asset

| Tool | Backing API |
|---|---|
| `import_asset(url, options)` | `ImporterRegistry.importer(for:)` → `AssetImporter` → `ImportResult` |
| `normalize_asset(path)` | `ConversionPipeline` — auto-scale to real-world ref, orient +Y up / −Z fwd, dedupe materials, validate before commit |

Import is not integration. `import_asset` always chains into `normalize_asset` +
`validate` before the prim is committed to the stage.

**Generative & library assets.** The single biggest lesson from BlenderMCP's success: agents
compose real assets far better than they synthesize geometry. Two additions, both funneling
through the same `import_asset` → `normalize_asset` → `validate` hygiene path:

| Tool | Notes |
|---|---|
| `search_assets(query, source?)` | curated library search (local library first; pluggable providers, e.g. PolyHaven-style CC0 catalogs) |
| `generate_asset(prompt, provider, options)` | text/image-to-3D via pluggable providers (Meshy, Tripo, Hyper3D Rodin — all export USDZ/GLTF); **async job**: returns `jobId` |
| `asset_job_status(jobId)` / `fetch_asset(jobId)` | poll → download → auto-import with cleanup (scale/orient/dedupe/decimate) |

Generation is submit/poll/import (never blocking a tool call on a cloud render), provider keys
via env vars, and the MCP server — not the generator — owns import hygiene. Downloaded/generated
files land under a project asset folder with metadata + job history (Meshy's auto-organization
pattern), so builds are reproducible.

### 3.6 Transaction control

| Tool | Backing API |
|---|---|
| `undo()` | `CommandStack.undo()` |
| `redo()` | `CommandStack.redo()` |
| `undo_to(token)` | replay to a prior step |
| `save()` | `StageSaver` |

### 3.7 Escape hatch (sandboxed)

| Tool | Backing API |
|---|---|
| `run_script(manifest, args)` | `ScriptRunner.run(...)` → `ScriptRunResult` |

Capped, reviewable surface via `ScriptExecuting` / `ScriptManifest` + `ScriptRunOptions`.
Never raw interpreter access. Emits `ScriptProgress`; re-imports result through the same
`import_asset` normalization path. Used only for the long tail the typed verbs don't cover.

## 4. Closed-loop scoring (`score`)

Each build step the agent may call `score(intent)`, which returns a fidelity score and the
set of failing gates. Gates, in order:

1. **Schema** — `ValidationEngine` / `ComplianceChecker` report zero `.error` diagnostics.
2. **Mesh integrity** — `MeshInvariants` pass (manifold, consistent normals, no degenerate faces).
3. **Scale sanity** — `MetersPerUnitRule` + bbox within plausible real-world range.
4. **Spatial** — no unintended interpenetration; declared relationships hold (bbox/raycast).
5. **Visual** — multi-view render matches intent (agent-judged).

The agent iterates mutate → validate → score until gates pass or a step budget is hit.
This is the same closed-loop discipline as the headless `verify` harness and coverage gate.

**Budget verification explicitly.** BlenderGym's core finding: spending inference compute on
verification beats spending it on more generation attempts. The step budget should reserve
verification calls (roughly one `score`/`check_mesh` per 2–3 mutations) rather than treating
them as overhead — and gates 1–4 are pure geometry (cheap, exact), so renders (gate 5) are
reserved for genuinely visual judgments.

## 5. Spatial relationship solver

`set_transform` accepts an optional `relativeTo` clause instead of absolute values:

```
set_transform(path: "/Cup", relativeTo: { anchor: "/Table", rule: "on_top", align: "center" })
```

The engine resolves it from the two prims' world-space bounding boxes and snapping math
(reusing `TransformDragSession` translate/rotate/scale + gizmo math), producing a concrete
`SetTransformCommand`. This converts weak LLM coordinate reasoning into deterministic placement.

## 6. Context economy & workflow recipes

- **Tool groups, activated per session.** The full surface is ~30 tools; large flat tool lists
  bloat context and increase wrong-tool picks (dcc-mcp-maya, unity-mcp both converged on staged
  loading). Group as `read` / `mutate` / `verify` / `render` / `asset` / `script`; a client can
  request a lean profile (e.g. read+verify only for an audit agent).
- **Workflow recipes as MCP Prompts.** Ship curated multi-step templates for the flows agents
  most often fumble — "import & normalize an asset", "recolor a material safely",
  "build → validate → score loop", "fix validation errors" — each naming exact tools, parameter
  conventions, and gate expectations. RTX Remix credits these with materially reducing
  multi-step errors; Meshy ships tool-chain guidance for the same reason.
- **Knowledge stays separate from mutation** (NVIDIA's split): if we later add USD-schema or
  API doc lookup tools, they live in their own group and never widen the mutation surface.

## 7. Safety & reliability

- **Transactional isolation** — every action is one undoable command; `batch` groups atomically.
- **No silent corruption** — typed verbs validate inputs before touching the stage; invalid ops fail with a structured error, not partial mutation.
- **Sandboxed scripting** — `run_script` runs through `ScriptRunOptions` limits, never arbitrary execution.
- **Validate-before-commit** — asset imports and script results pass `validate` before entering the stage.
- **Stateless-safe** — server holds authoritative `EditSession` state; agent context can be reconstructed from `describe_scene` at any time.
- **Main-thread marshaling** — the universal correctness bug across surveyed servers. When the MCP server drives a live editor document (vs. headless), every stage mutation is dispatched onto the app's main actor; tool handlers never touch `BridgedStage` from the transport thread.
- **Transport** — stdio first (works everywhere today). The ecosystem direction (Epic UE 5.8) is an in-process streamable-HTTP server on localhost; design the adapter so transport is swappable and the in-app server can ship later without touching tool code. Keep each tool call small — bridge timeouts on big payloads are BlenderMCP's most-reported flakiness; `batch` exists so *transactions* can be big while *calls* stay small.

## 8. Build phases

1. **P1 — Read + transactional mutate.** MCP server, `EditSession`, §3.1 read tools (incl. `describe_scene`), §3.2 mutate tools mapped to existing `EditCommand`s, stable `primId` handles, §3.6 undo/redo/save. Inline `validate` (warn mode) on every mutate.
2. **P2 — Verify loop.** §3.3 `check_mesh` / `score` + strictness modes, gate ordering (§4). Multi-view / isolated `render_views` with `stats_only` (§3.4).
3. **P3 — Spatial solver.** `relativeTo` resolution (§5) on `set_transform`.
4. **P4 — Assets.** `import_asset` + `normalize_asset` chain, `search_assets`, and async `generate_asset` job flow (§3.5).
5. **P5 — Escape hatch + polish.** Sandboxed `run_script` (§3.7); MCP resources, tool groups, and workflow-recipe prompts (§6).

Each phase is independently shippable and leans entirely on already-shipped `*Kit` APIs;
the MCP server adds adaptation and serialization only.

## 8. Live activity bridge (app ⇄ server)

The editor app surfaces a live view of an agent's session: an **activity panel**
(each tool call with running/✓/✕ status, duration, and a one-line summary) and a
**menu-bar tray** (connection status, served file, tool count, and copy-paste setup
commands). Because `openusdz mcp` runs as a separate process from the app, and
`dependency-lint` forbids the app/`EditorUI` from importing `AgentMCP`, the two sides
communicate over a **localhost socket** whose **JSON wire format is the only contract** —
each side keeps its own Codable mirror.

**Discovery.** The app hosts an `NWListener` on `127.0.0.1` (ephemeral port) and writes
`~/Library/Application Support/OpenUSDZEditor/mcp/endpoint.json` `{port, pid, token}` on
launch (removed on quit). The server's sink reads this lazily, verifies the app pid is
alive (`kill(pid,0)`), connects, and re-reads on failure. App not running ⇒ the sink is a
graceful no-op and never blocks the tool path.

**Protocol (NDJSON, one object per line).** Every event carries `v` (schema version) and
`pid` (so calls key by `(pid, seq)` across concurrent servers):

- `session_start` `{v,type,pid,protocolVersion,servedFile,toolCount,groups[],ts}` — re-sent on each reconnect
- `tool_started`  `{v,type,pid,seq,tool,argsSummary,ts}`
- `tool_finished` `{v,type,pid,seq,tool,durationMs,isError,summary,ts}`
- `heartbeat`     `{v,type,pid,ts}`
- `session_end`   `{v,type,pid,ts}` (also inferred from socket close)

`argsSummary`/`summary` are truncated (~200 chars) in the producer.

**Placement.** `AgentMCP` only defines `MCPEventSink` and fires it from the single
`callTool` choke point (pure, 100%-covered). The concrete NDJSON socket sink lives in
`CLI` (`SocketEventSink`); the localhost listener + reducer live in the `App` target
(`MCPActivityListener`), which is not coverage-gated. The panel and its `MCPActivityModel`
live in `EditorUI`.
