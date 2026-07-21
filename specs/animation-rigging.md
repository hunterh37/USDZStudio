# Animation & Rigging Specification — RigKit, Skeleton/Anim Authoring, Auto-Rig & Humanoid Retargeting

## Scope Statement

This spec covers the full character-animation authoring domain, delivered across four roadmap phases:

- **Phase 10 — Skeleton & Animation Authoring (v1.5):** the raw UsdSkel data-authoring foundation. Edit joint hierarchies, rest/bind transforms, skin weights (manual paint), blendshapes, and keyframe/clip data on a timeline. No solvers.
- **Phase 13 — Production Rigging & Skinning (v2.1):** control rigs on top of raw joints — IK/FK chains, constraints, control handles — plus automatic skin-weight *solving*.
- **Phase 14 — Auto-Rigging (v2.2):** one-click skeleton fit + weight solve for an unrigged mesh, humanoid and generic.
- **Phase 15 — Humanoid Retargeting & Motion Library (v2.3):** a canonical humanoid rig standard, motion import (BVH/FBX/glTF/mocap), retargeting onto any rigged humanoid, and a clip blend/state-machine library.

Playback already ships (Phase 1, RealityKit `AnimationResource` via `PlaybackTransport`). **This spec authors what that plays.** The USD stage remains the single source of truth; the RealityKit scene is a derived projection (per `specs/architecture.md`).

The **manual UI** counterpart to the agent-facing `.rig` tool group — the Animator Dock, viewport rigging gizmos, and inspector tabs, plus how the manual and MCP paths share one command funnel — is specified in `specs/animation-ui.md`.

Designed — like MeshKit — to be **built and verified by LLM code agents**: every solver and transform is a pure function on value types with machine-checkable correctness invariants, so an op's correctness is provable without a human eyeball.

### Non-goals

- A general node-graph animation DCC (Maya/Blender parity). We author UsdSkel structures directly with focused tools.
- Muscle/cloth/hair simulation, physics-based secondary motion (may revisit; not in these phases).
- Facial-capture / audio-driven animation.

## Review conclusion (2026-07) — what this enhancement closes

An audit against the two sibling agent-authoring specs (`sculpt-pipeline.md`, `articulation-mechanisms.md`) found the RigKit **deterministic-math foundation is state-of-the-art** (pure leaf, solver contract, export-profile degradation, invariant harness) but the **agent-runtime layer is missing** — the exact layer that makes the other two pipelines usable by a coding agent (Claude, via the `openusdz` MCP server). Four gaps, now specified below:

1. **No discoverable MCP tool group.** Rig/anim ops are reachable only through the generic `run_script` `app.*` seam. An agent doing `tools/list` sees nothing that says "you can animate." → New `.rig` tool group (§MCP surface).
2. **No bone-name identification.** `Retarget/HumanoidMap.swift` holds the canonical names internally, but no tool lets the agent introspect an unknown skeleton and get *proper bone names with confidence*, so an agent would be authoring against guessed joint paths. → `list_joints` + `identify_skeleton` (§Bone-name identification).
3. **"Smooth / realistic" is asserted, not measured.** The harness proves solver determinism and convergence; nothing scores *motion quality*. → A deterministic **motion-quality metric** + `motionQualityFloor` gate, the runtime analog of sculpt's `measuredSimilarity` (§Motion quality).
4. **No agent self-validation loop.** The invariant harness runs at *build* time (CI). There is no *agent-runtime* gate like sculpt's render→measure→score→continue. → The **animation review-loop contract** (§Self-validation loop).

The RigKit math foundation, package position, and export table below are unchanged; the new sections are the agent-facing spine layered on top, and every new metric/gate is itself invariant-checkable per the repo discipline.

## Prerequisite — close the time-sampled round-trip gap (Phase 10, first)

Today `USDASerializer` drops purely time-sampled channels on save: an attribute the bridge surfaces as `.unsupported` (a time-sampled channel with no default-time value) is written as an "omitted" comment. This is a **declared gap** in `scripts/roundtrip-gate.sh` `EXPECTATIONS` (recorded in the Milestone 4 note and `specs/testing.md` §Test Layer 4). Animation authoring is untrustworthy until `open → save → open` preserves samples exactly.

**Required before any animation authoring UI:** `USDASerializer` emits `.timeSamples` blocks for these channels, and the gate's `EXPECTATIONS` row is tightened (a declared-failing invariant that starts passing must be recorded — same ratchet discipline as `coverage-gate.sh`). The existing `USDCore` data model already carries what is needed: `TimeSample`, `Attribute.isAnimated`, `quatf[]`/`float3[]`/`matrix4d` value kinds, and the `skel:*` relationships. The gap is in serialization, not the model.

## New Package: RigKit

```
RigKit (pure Swift, zero internal dependencies, 100% coverage tier)
├── Skeleton              # joint hierarchy value type (stable joint IDs, rest/bind pose)
├── Pose                  # per-joint local/world transform sampling; FK evaluation
├── Skin                  # weight table (jointIndices/jointWeights), normalize/prune/clamp
├── Solvers/
│   ├── TwoBoneIK.swift   # analytic limb solver (closed form)
│   ├── CCD.swift         # cyclic coordinate descent, general chains
│   ├── FABRIK.swift      # forward-and-backward reaching, general chains
│   └── Constraints.swift # parent/point/orient/aim/scale, weighted, ordered eval
├── AutoRig/
│   ├── SkeletonFit.swift # geometry/landmark skeleton placement, symmetry-aware
│   └── WeightSolve.swift # heat-diffusion / bone-glow skin binding
├── Retarget/
│   ├── HumanoidMap.swift # canonical bone-name standard + arbitrary-skeleton binding
│   └── Retargeter.swift  # source→target motion mapping, rest-pose reconciliation
├── Clips/                # clip model, blend/additive layers, blend-graph evaluation
├── MotionQuality.swift   # pure motion-quality sub-metrics (jerk/foot-slide/interpenetration/limit/seam) + weighted blend
└── Invariants            # shared validation used by solvers and tests
```

The **agent-runtime layer** (the `.rig` MCP tool group, `RigStore` actor, workflow prompts) lives in `AgentMCP` as thin handlers over `RigKit` + `EditSession` — the same split as the `.sculpt` group over `SculptKit`. `RigKit` stays a pure leaf; no MCP/render/persistence code enters it.

**Dependency position (to be wired in the phase's PR, per the module-governance ritual):** `RigKit` is a leaf — it imports nothing internal (it may share nothing with `MeshKit`; both are pure leaves). `EditingKit ─▶ RigKit` (wraps solves in undoable commands) and `ViewportKit ─▶ RigKit` (rig-handle overlay rendering) are added to `scripts/dependency-lint.sh` and `specs/architecture.md` in the same PR. `RigKit` never imports UI, GPU, or Python frameworks (framework ban enforced by the lint script, same as USDCore/MeshKit).

> **Governance checklist (same PR, per `specs/architecture.md`):** dependency-lint policy entry; architecture layout + dependency-rules update; `specs/testing.md` floor row (`RigKit` **100%** logic); test target with real tests; `scripts/test-all.sh` entry; this spec cross-referenced. An ungoverned package fails CI by construction.

### Skeleton & Pose

- Value-semantic (`struct`, CoW) — snapshot-based undo, safe concurrency.
- Stable joint IDs across edits (selection persistence, undo, weight-table integrity).
- Maps losslessly to/from UsdSkel: `joints` (`token[]` paths), `restTransforms`/`bindTransforms` (`matrix4d[]`), and animation channels (`translations` `float3[]`, `rotations` `quatf[]`, `scales` `float3[]` — the value kinds `USDCore` already models).
- FK evaluation is pure: `world(joint) = world(parent) · local(joint)`; deterministic, order-independent given the hierarchy.

### Solver contract

```swift
public protocol RigSolver {
    associatedtype Params
    /// Pure: no side effects. Deterministic — same input yields the same pose.
    /// Returns the solved pose plus a convergence report; never silently fakes a solve.
    static func solve(_ skeleton: Skeleton, pose: Pose, params: Params) -> SolveResult
}
```

`SolveResult` reports `converged: Bool`, `iterations`, and `residual` — a non-converging solve is a reported outcome, not a thrown error or a silent bad pose (mirrors MeshKit's precondition-diagnostic discipline).

### Heavy-solve assist path

Auto-rig weight solves and mesh-heavy fits *may* delegate to the bundled Python + `usd-core`/scientific libraries for performance (per the "scriptable power" pillar). The rule: **every invariant-checkable computation lives in `RigKit`** as pure Swift with a golden reference; Python is an optional accelerator behind the same result contract, injected and excluded from the logic gate with an annotated reason (same pattern as USDBridge's interpreter seams).

## Export-profile degradation table

Every construct is measured against the active export profile (RealityKit/QuickLook default; `lossless`/`full-USD` for advanced work), per PRD Pillar 2 — flagged, never silently destroyed.

| Construct | RealityKit / QuickLook profile | lossless / full-USD |
|---|---|---|
| Baked joint animation (UsdSkel `SkelAnimation`) | Preserved | Preserved |
| Blendshapes / targets | Preserved (RealityKit-supported) | Preserved |
| Skin weights | Clamped to max influences per vertex; normalized | Preserved as authored |
| IK/FK chains, constraints, control rig | **Baked** to per-joint keyframes on export; rig metadata flagged non-portable | Rig authoring intent preserved as custom data |
| Blend graph / state machine | Baked to concrete clips/timesamples | Graph preserved as custom schema |
| Humanoid bone-map | Emitted as custom metadata; ignored by RealityKit | Preserved |

The exporter surfaces exactly what bakes and what drops before write, via the existing `ExportGate`/`ComplianceChecker` path.

## Per-phase authoring surface

### Phase 10 — foundation
Joint hierarchy edit, rest/bind transform edit, manual weight paint, blendshape/target authoring, keyframe authoring + timeline (create/trim/retime/blend clips), and the skinned-mesh editing lift (replace the Phase 6 hard refusal with weight-propagating edits). All as undoable `EditingKit` commands over the stage.

### Phase 13 — production rigging & skinning
IK/FK chains (2-bone analytic, CCD, FABRIK) with pole vectors and per-chain FK/IK blend; constraints (parent/point/orient/aim/scale, weighted, ordered); control-rig authoring (control curves/handles bound to joints, viewport manipulation reusing the gizmo hit-test seam); automatic weight solve (heat-diffusion) with normalize/prune/mirror and RealityKit influence clamp.

### Phase 14 — auto-rigging
Skeleton auto-fit (geometry/landmark heuristics, symmetry-aware, humanoid landmark detection, scale-normalized); automatic weight solve on the fit; "confirm & adjust fit" preview UI (nudge joints, re-solve, accept as one undoable command); generic fallback fit for non-humanoid meshes.

### Phase 15 — humanoid retargeting & motion library
Canonical humanoid rig standard (named bone map + mapping UI to bind arbitrary skeletons); motion import (BVH/FBX/glTF-skel/mocap → normalized clip); retargeting (bone correspondence, rest-pose reconciliation, hip-height/scale normalization, foot-slide minimization); clip library with blend/additive layers and a state-machine/blend-graph authoring surface; bake to UsdSkel animation.

## MCP surface — the animation tool group (`.rig`)

The point of the request: **a coding agent must be able to discover it can animate, identify the right bones without guessing, author smooth motion, and confirm its own result.** Following the sculpt/articulation pattern, discovery is via `tools/list` descriptions + a `prompts/list` workflow recipe. All handlers are thin: they drive `RigKit` (pure math) and realize results through `EditSession.mutate` as undoable `EditingKit` commands. Cross-call agent state (active rig target, current clip, last motion score + floor) lives in a `RigStore` actor, persisted to `<workDirectory>/rig-{session}.json` and restored on construction, exactly like `SculptStore`.

Handlers stay decode-free/render-free where RigKit is pure; the only impure seams are the existing `render_views` (offscreen frames) and the pixel/geometry sampling used by the motion-quality metric — injected and coverage-annotated, matching `RasterLoader` in the sculpt pipeline.

### Introspection & bone identification

- `list_joints { prim? }` — return the skeleton hierarchy for a `UsdSkel` under `prim` (or the active rig): each joint's `path`, `parent`, rest/bind transform, child count, and influence-count summary. Pure read over the stage snapshot. This is how the agent *sees* the rig instead of guessing paths.
- `identify_skeleton { prim? }` — run `Retarget/HumanoidMap` fuzzy matching over the joint set and return, **per canonical humanoid bone** (`Hips`, `Spine`, `LeftUpperArm`, `RightHand`, …), the best-matching authored joint path **with a confidence score in 0…1** and the alternates considered. Ambiguous or unmatched canonical bones are reported as such (never silently mapped). This is the "Claude can identify proper bone names" capability — see §Bone-name identification.
- `rig_status { }` — current agent state: active rig, whether a canonical map is bound, current clip, last `measuredMotionQuality` + the active `motionQualityFloor`, and which self-validation gates are outstanding.

### Authoring

- `set_joint_pose { joint, translation?, rotation?, scale? }` — author one joint's local transform (undoable). FK-evaluated preview.
- `solve_ik { chain: [rootJoint…effector], target:[x,y,z], poleVector?:[x,y,z], solver? }` — run the analytic 2-bone / CCD / FABRIK solver and author the resulting pose. Returns the `SolveResult` (`converged`, `iterations`, `residual`) verbatim — a non-converging solve is a reported outcome the agent must handle, never a silent bad pose.
- `set_keyframe { joint, timeCode, translation?/rotation?/scale? }` and `create_clip { name, startTimeCode, endTimeCode }` / `edit_clip { name, trim?/retime?/blend? }` — keyframe + clip authoring on the timeline (Phase 10). Writes go through the closed time-sample round-trip path (prerequisite above).
- `auto_rig { mesh, kind: humanoid|generic, seed? }` — Phase 14 one-click skeleton fit + weight solve; returns the proposed skeleton for the "confirm & adjust" preview. Deterministic given `seed`.
- `solve_weights { mesh, skeleton, maxInfluences? }` / `paint_weights { … }` — heat-diffusion weight solve or manual paint, with normalize/prune/clamp to the export profile cap.
- `retarget_clip { sourceClip, targetRig }` — Phase 15 retargeting onto a canonical-mapped humanoid; rest-pose reconciliation + hip-height/scale normalization + foot-slide minimization.

### Preview & self-validation

- `render_pose { }` / `render_clip { sampleTimes:[…] }` — offscreen frames of the current pose or of clip samples (reuses `render_views`); the evidence the agent's continue-gate requires.
- `assess_motion { clip?, sampleTimes? }` — the **deterministic motion-quality metric** (§Motion quality). Returns `measuredMotionQuality` plus its component sub-scores (smoothness/jerk, foot-slide, interpenetration, limit-compliance, seam-continuity). Fed back into the review loop; the continue-gate enforces it against `motionQualityFloor`.
- `rig_review { decision, subjectiveScore?, motionQuality? }` — record one `RigDecision` (§Self-validation loop).

## Bone-name identification

An agent must never author against a guessed joint path. `identify_skeleton` binds an arbitrary authored skeleton to the **canonical humanoid standard** (the Phase 15 named bone map — Mixamo / Unity-Humanoid style) so downstream tools and the agent speak in stable canonical names (`LeftUpperLeg`) regardless of the file's raw naming (`mixamorig:LeftUpLeg`, `thigh.L`, `Bip01_L_Thigh`).

- **Matching is deterministic and explainable.** For each canonical bone the matcher scores authored joints on normalized-name token similarity, hierarchy position (depth + parent/child role), and symmetry pairing (left/right must map consistently). It returns the top candidate + confidence + the alternates, so a low-confidence or tied match is *visible*, not hidden.
- **The agent confirms before authoring.** The `identify-and-animate` workflow prompt requires the agent to review the mapping (and, when confidence is below a threshold or a required bone is unmatched, ask the user or inspect further via `list_joints`) **before** any pose/retarget call. Guessing is designed out of the loop.
- **Invariant-checkable.** The map is validated: canonical names unique; left/right symmetric; no authored joint claimed by two canonical bones; parent canonical bones map to ancestors of their children's mapped joints. Golden fixtures over a committed multi-naming skeleton corpus assert the mapping (per-bone match within expectation, deterministic given the corpus).

## Motion quality — making "smooth & realistic" measurable

"Smooth and realistic" is promoted from an aspiration to a **deterministic, machine-checkable score**, the runtime analog of the sculpt pipeline's `measuredSimilarity`. `assess_motion` samples the evaluated pose over `sampleTimes` and computes a weighted blend of stable sub-metrics (fixed resample, resolution-independent, machine-stable):

- **Smoothness (jerk):** the normalized third derivative of joint world-position over time — low jerk ⇒ smooth. Discontinuities at clip seams are penalized (C1/velocity continuity across `edit_clip` blends).
- **Foot-slide:** planted-foot horizontal drift while the foot is in contact (the classic retarget artifact) — the Phase 15 metric surfaced at runtime.
- **Interpenetration:** limb/body self-intersection sampled over the clip (coarse capsule proxies from the skeleton).
- **Limit compliance:** every sampled joint value within its authored rotation limits; IK residual within tolerance.
- **Naturalness priors:** velocity-profile bell-shape (ease-in/ease-out rather than linear robotic motion) and pose-plausibility against joint-limit soft ranges.

`assess_motion` returns `measuredMotionQuality` (the worst-weighted blend, so one bad sub-metric can't be masked) plus every component. The **continue-gate enforces `measuredMotionQuality ≥ motionQualityFloor`** — the deterministic gate a subjective vision score cannot bypass (mirrors sculpt's `similarityFloor`). When a clip can't be sampled the tool reports no measurement and the floor is not enforced for that step (the subjective score still gates). All sub-metrics are pure functions in `RigKit` with golden reference values; only pose sampling is a seam.

## Self-validation loop — agents validate their own work

Directly mirrors the sculpt review-loop contract, so the two pipelines are learnable as one pattern. After each authoring step (a solved pose, an authored clip, a retarget) the agent records one `RigDecision`:

`continue | refinePose | resolve | requestInput | stop`

The **continue-gate** requires all of: a render (`render_pose`/`render_clip`), a deterministic `assess_motion` measurement, `measuredMotionQuality ≥ motionQualityFloor`, **and** a subjective vision score ≥ the threshold. Missing evidence, a floor miss, or a low subjective score is rejected — the agent must `refinePose`/`resolve` (re-solve or re-key) and try again. `requestInput` pauses (e.g. an ambiguous bone mapping); `stop` halts.

The completion gate additionally runs the ARKit `ComplianceChecker` over the finished animated stage (the `check_compliance` path) so the exported clip is confirmed RealityKit/QuickLook-portable, not merely visually accepted — the animation analog of sculpt's AR-compliance completion gate.

### Workflow prompts (`WorkflowPrompts.swift`)

- `identify-and-animate` — the headline recipe: `list_joints` → `identify_skeleton` (review the canonical map; resolve low-confidence bones before proceeding) → author (`solve_ik` / `set_keyframe` / `create_clip`) → `render_clip` → `assess_motion` → `rig_review`, looping until the continue-gate passes → `check_compliance` → `save`.
- `retarget-motion` — import a clip, `identify_skeleton` on both source and target, `retarget_clip`, then the same assess/review loop with foot-slide and seam-continuity emphasized.
- `auto-rig-mesh` — `auto_rig` → confirm the proposed skeleton (`list_joints`) → `solve_weights` → a test `solve_ik` pose → assess/review.

## Test & Invariant Harness (Phase T rule — same PR as each op)

`RigKit` carries a **100% coverage floor + fuzz corpus** (like MeshKit). Per-phase invariants:

- **Solver determinism:** identical input → byte-identical output pose (fuzzed over random skeletons/targets).
- **Solver convergence:** analytic 2-bone reaches an in-reach target within tolerance; iterative solvers either converge within a bound or report `converged == false` (no silent bad pose).
- **Skin invariants:** per-vertex weights sum to 1 (within ε) after normalize; influence count ≤ profile cap after clamp; mirrored weights are symmetric.
- **Skeleton round-trip:** `Skeleton`/`Pose`/`Skin` → UsdSkel → back is lossless on untouched channels; joint-transform round-trip.
- **Time-sampled round-trip:** authored animation channels survive `open → save → open` (the closed Phase 10 gap; red-on-regression in `roundtrip-gate.sh`).
- **Auto-fit golden fixtures:** proposed skeletons over a committed mesh corpus match golden joint positions within tolerance; left/right symmetry invariant; deterministic given a seed; weight-quality metrics as golden values.
- **Retarget round-trip:** identity retarget onto a matched skeleton reproduces the source pose within tolerance; foot-slide / normalization metrics as golden values.
- **Golden posed frames:** deterministic sampled-pose offscreen renders per solver and per clip (perceptual ΔE gate, per `specs/testing.md` §7).
- **Bone-identification golden fixtures:** over a committed multi-naming skeleton corpus (`mixamorig:*`, `*.L/.R`, `Bip01_*`), `identify_skeleton` maps each canonical bone within expectation, is deterministic, symmetric, and reports low-confidence/unmatched bones rather than mis-mapping (§Bone-name identification invariants).
- **Motion-quality metric goldens:** each sub-metric (jerk/smoothness, foot-slide, interpenetration, limit-compliance, seam-continuity) is a pure function with golden values over a fixed clip corpus; the worst-weighted blend is stable across machines. A hand-authored smooth clip scores above, and a jittery/foot-sliding one below, `motionQualityFloor`.
- **Self-validation gate contract test:** the continue-gate rejects a step lacking a render, lacking an `assess_motion` measurement, below `motionQualityFloor`, or below the subjective threshold; accepts only when all hold; completion runs `check_compliance` and blocks a non-portable clip.
- **MCP contract tests:** `list_joints`/`identify_skeleton`/`solve_ik`/`set_keyframe`/`assess_motion`/`rig_review` drive a real `EditSession`; `RigStore` persists and restores session state across a server restart (parity with `SculptStore`).
- **Export-profile degradation snapshots:** what each rig construct bakes to under RealityKit vs. full-USD (per Phase 12's degradation-snapshot pattern).

The `.rig` handlers are held to the same 100% logic floor as the sculpt handlers; genuinely-defensive command-construction catches carry `// coverage:disable` with a rationale, matching the rest of AgentMCP.

## Console & CLI parity

Per the Continuous/Platform roadmap section: every rig/anim op is scriptable through the injected `app.*` API with single-undo script runs, reachable from the ⌘K command palette via `ActionRegistry`, exposed as the `.rig` MCP tool group above (discoverable via `tools/list` + the `identify-and-animate` workflow prompt), and — because the app hosts the MCP session (`specs/agent-live-editing.md`) — every agent pose/clip edit renders live in the running viewport and is `⌘Z`-undoable. Batch retargeting and batch auto-rig are exposed as CLI subcommands, consistent with the existing `convert`/`validate`/`recolor` pipeline tools.
