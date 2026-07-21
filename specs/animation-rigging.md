# Animation & Rigging Specification — RigKit, Skeleton/Anim Authoring, Auto-Rig & Humanoid Retargeting

## Scope Statement

This spec covers the full character-animation authoring domain, delivered across four roadmap phases:

- **Phase 10 — Skeleton & Animation Authoring (v1.5):** the raw UsdSkel data-authoring foundation. Edit joint hierarchies, rest/bind transforms, skin weights (manual paint), blendshapes, and keyframe/clip data on a timeline. No solvers.
- **Phase 13 — Production Rigging & Skinning (v2.1):** control rigs on top of raw joints — IK/FK chains, constraints, control handles — plus automatic skin-weight *solving*.
- **Phase 14 — Auto-Rigging (v2.2):** one-click skeleton fit + weight solve for an unrigged mesh, humanoid and generic.
- **Phase 15 — Humanoid Retargeting & Motion Library (v2.3):** a canonical humanoid rig standard, motion import (BVH/FBX/glTF/mocap), retargeting onto any rigged humanoid, and a clip blend/state-machine library.

Playback already ships (Phase 1, RealityKit `AnimationResource` via `PlaybackTransport`). **This spec authors what that plays.** The USD stage remains the single source of truth; the RealityKit scene is a derived projection (per `specs/architecture.md`).

Designed — like MeshKit — to be **built and verified by LLM code agents**: every solver and transform is a pure function on value types with machine-checkable correctness invariants, so an op's correctness is provable without a human eyeball.

### Non-goals

- A general node-graph animation DCC (Maya/Blender parity). We author UsdSkel structures directly with focused tools.
- Muscle/cloth/hair simulation, physics-based secondary motion (may revisit; not in these phases).
- Facial-capture / audio-driven animation.

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
└── Invariants            # shared validation used by solvers and tests
```

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
- **Export-profile degradation snapshots:** what each rig construct bakes to under RealityKit vs. full-USD (per Phase 12's degradation-snapshot pattern).

## Console & CLI parity

Per the Continuous/Platform roadmap section: every rig/anim op is scriptable through the injected `app.*` API with single-undo script runs, and reachable from the ⌘K command palette via `ActionRegistry`. Batch retargeting and batch auto-rig are exposed as CLI subcommands, consistent with the existing `convert`/`validate`/`recolor` pipeline tools.
