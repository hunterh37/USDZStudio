# Articulation & Mechanisms Specification — Hinged / Swingable Rigid Parts (Lids, Doors, Caps, Drawers)

## Scope Statement

This spec covers **rigid-body articulation**: making a part of an object *open, close, swing, slide, or rotate about a fixed axis* — an AirPods-case lid that flips up, a chest that opens, a door on a hinge, a bottle cap that twists off, a drawer that slides. It is the mechanical counterpart to `specs/animation-rigging.md`:

- **`animation-rigging.md` (RigKit)** authors **skeletal deformation** — joints that *bend a skinned mesh* (a character's elbow). Weights, bind poses, IK/FK.
- **This spec (MechanismKit)** authors **rigid articulation** — a *whole sub-assembly pivots as one solid piece* about a mechanical axis. No skinning, no weights. A lid does not deform; it rotates rigidly about its hinge line.

The two share nothing at the data level and must not be conflated. A coding agent asked to "make the lid open" needs *this* spec, not skeletal rigging.

### Why this is a gap (review conclusion)

An audit of the codebase (2026-07) found **no articulation capability anywhere**, and confirmed there was nothing to inherit from the upstream `img2threejs` package we borrowed the sculpt-runtime model from — its own `docs/UPGRADE_PLAN.md` records "Rig/pivot hierarchy for animation is a future refinement," i.e. unbuilt. Concretely, today:

- `SculptKit.Socket` is a **static point** (`name` + `translation`) — an attach anchor, carrying no axis, pivot, angle range, or moving state. `AttachmentKind` names "socket/pivot" only in a comment.
- `ConversionKit` authors rigid nodes as a single baked `xformOp:transform` matrix — no pivot op, no rotate-about-a-point.
- The MCP surface cannot build a hinge: `set_transform`'s `TRS` has **no pivot** (rotation is always about the prim's own origin); `set_variant` can only **select** an existing variant, with **no command to create a variant set or add variants**; `set_attribute` cannot author time samples; there is no joint / physics / animation-authoring tool.
- The time-sampled round-trip is a **declared-open gap** (`scripts/roundtrip-gate.sh`, `animated.usda`), so baked swing *animation* is untrustworthy through save; discrete open/closed *variants* are not affected.

### Non-goals

- Skeletal skinning / deformation (that is RigKit).
- Full rigid-body dynamics simulation (gravity, collision response). Physics *joint declaration* for interactive profiles is in scope (Phase D); solving is not.
- Gears/linkages/constraint networks between multiple joints (may revisit; single independent joints only here).
- Soft-body, cloth, springs.

## The core problem: pivots

Every mechanism reduces to **rotating (or sliding) a sub-assembly about an axis that does not pass through the part's own local origin.** A lid hinges about its *rear edge*, not its centre. Nothing in the stack can express that today:

- `set_transform` rotates about the prim origin only.
- Our authoring emits one collapsed `xformOp:transform` matrix — we never emit the USD `xformOp:translate:pivot … xformOp:rotateXYZ … !invert!xformOp:translate:pivot` op-order that USD uses for off-origin pivots.

**Resolution — the pivot-Xform pattern (structural, not op-order).** Rather than teach the transform pipeline a pivot op, we author the moving part *under a dedicated pivot `Xform` whose local origin sits on the hinge axis*. Rotating that pivot Xform about its own origin then rotates the child about the hinge line — using only the single-matrix authoring we already have. Hierarchy:

```
Chest            (Xform)              — the assembly root
├── Base         (Mesh/…)             — the static body
└── Lid_pivot    (Xform)              — origin ON the hinge line; carries the state/anim/joint
    └── Lid      (Mesh/…)             — offset so its geometry sits where it belongs when closed
```

This is deterministic, invariant-checkable, and portable to every export profile. The optional explicit `xformOp:translate:pivot` op-order is reserved for the `full-USD` profile (Phase C) where authored intent should survive as native pivot ops.

## New Package: MechanismKit

Mirrors the RigKit governance pattern: a **pure Swift leaf, zero internal deps, 100% coverage tier.** All joint math is a pure function on value types with machine-checkable invariants, so correctness is provable without a human eyeball (the MeshKit/RigKit discipline).

```
MechanismKit (pure Swift, zero internal deps, 100% coverage tier)
├── Joint                 # value type: kind, axis, pivot, limits, states, target component
├── JointKind             # .revolute (hinge) | .prismatic (slider)
├── JointState            # a named pose: e.g. {closed: 0°}, {open: 105°}
├── PivotMath.swift        # pose→local-matrix for the pivot Xform; rotate/slide about (pivot, axis)
├── JointInvariants.swift  # axis-fixed-point, limit ordering, state-in-range, rest==closed
└── Manifest              # articulation entries appended to the sculptRuntime manifest
```

**Dependency position (wired in the phase PR, per the module-governance ritual):** `MechanismKit` is a leaf — imports nothing internal (shares nothing with MeshKit/RigKit; all three are pure leaves). Consumers, added to `scripts/dependency-lint.sh` and `specs/architecture.md` in the same PR:

- `SculptKit ─▶ MechanismKit` — articulation is part of the sculpt runtime layer (authored in the `interaction` pass; carried in `RuntimeManifest`).
- `EditingKit ─▶ MechanismKit` — undoable authoring commands (create-joint, set-state, variant-set authoring).
- `ViewportKit ─▶ MechanismKit` — hinge-axis gizmo overlay + drag-to-open handle (later; reuses the existing gizmo hit-test seam).

`MechanismKit` never imports UI/GPU/Python (framework ban enforced by the lint script, same as USDCore/MeshKit/RigKit).

> **Governance checklist (same PR, per `specs/architecture.md`):** dependency-lint policy entry; architecture layout + dependency-rules update; `specs/testing.md` floor row (`MechanismKit` **100%** logic + fuzz corpus); test target with real tests; `scripts/test-all.sh` entry; `scripts/roundtrip-gate.sh` fixtures; this spec cross-referenced. An ungoverned package fails CI by construction.

### Data model

```swift
public enum JointKind: String, Codable, Sendable { case revolute, prismatic }

/// A named articulation pose. `value` is degrees for .revolute, scene units for .prismatic.
public struct JointState: Codable, Sendable, Equatable {
    public var name: String        // USD-identifier-safe; e.g. "closed", "open"
    public var value: Double
}

public struct Joint: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String                 // USD-identifier-safe, unique in the assembly
    public var kind: JointKind
    public var target: String                // ComponentNode name of the moving part
    public var axis: [Double]                // local hinge/slide axis (normalized on author)
    public var pivot: [Double]               // hinge-line point, in the assembly-root local frame
    public var minValue: Double              // limit lower bound (deg or units)
    public var maxValue: Double              // limit upper bound; minValue <= maxValue
    public var states: [JointState]          // at least {closed, open}; each value in [min,max]
    public var defaultState: String          // which state the object loads in (QuickLook/RealityKit)
}
```

### Pivot math (pure, the invariant core)

`PivotMath.localMatrix(for: joint, valueDegOrUnits:)` returns the local `matrix4d` for the pivot Xform that realizes a given joint value:

- `.revolute`: rotation by `value` degrees about `axis` (Rodrigues), with the pivot Xform's origin already on the hinge line — so the child rotates about `pivot`. The pivot offset itself is baked into the pivot Xform's *rest translation* = `pivot`; the child's local translation is `-pivot` + its closed-world offset, so closed == geometry in place.
- `.prismatic`: translation by `value` along `axis`.

Invariants (`JointInvariants`, fuzzed):

- **Axis fixed-point:** every point on the hinge line maps to itself under the revolute pose, within ε (this is *the* correctness test for "rotates about the right axis").
- **Rest == closed:** the pose for the `closed` state (value 0 by convention) is identity on the pivot Xform.
- **Limit ordering:** `minValue <= maxValue`; every `JointState.value ∈ [minValue, maxValue]`.
- **Axis non-degenerate:** `|axis| > 0`; normalized deterministically.
- **State names:** unique, USD-identifier-valid; `defaultState` exists in `states`; `{closed, open}` both present.
- **Determinism:** identical joint + value → byte-identical matrix.

## USD authoring — three profile-aware representations

Every construct is measured against the active export profile (RealityKit/QuickLook default; `lossless`/`full-USD` for advanced work), per PRD Pillar 2 — flagged, never silently destroyed. The exporter surfaces exactly what bakes and what drops before write, via the existing `ExportGate`/`ComplianceChecker` path.

| Representation | How it's authored | RealityKit / QuickLook | lossless / full-USD |
|---|---|---|---|
| **A. Pivot Xform + state edit** (default) | The pivot `Xform` carries a single `xformOp:transform` (its current state) plus a `uniform string mechanism:joint` describing axis/pivot/limits/states. Open/close is `SetJointStateCommand` re-authoring that one matrix. | **Preserved** — pure standard Xform ops + one custom string attr. Ships in the part's `defaultState` pose; runtime tooling reads `mechanism:joint` to drive it. Round-trips through the existing serializer. | Preserved |
| **B. State variants** (enhancement) | A `state` **variant set** on the pivot; each variant (`closed`, `open`) authors the pivot's `xformOp:transform`, so both poses ship switchably in one file (the §5.2 variant switcher). | Preserved — QuickLook/RealityKit load the selected variant. Requires variant-scoped opinions, authored through the usd-core **bridge** (the Swift `VariantSet` projection carries no scoped content). | Preserved |
| **C. Baked swing** (enhancement) | `xformOp:transform` **time samples** on the pivot interpolating closed→open; stage `startTimeCode`/`endTimeCode` set. | Preserved **once the time-sample round-trip gap closes** (RealityKit `AnimationResource` plays it); flagged non-portable until then. | Preserved |
| **D. Physics joint** (enhancement) | A `UsdPhysics` `PhysicsRevoluteJoint`/`PhysicsPrismaticJoint` with `physics:axis`, anchors from `pivot`, `physics:lower/upperLimit`. | **Baked** to A (discrete) or dropped; flagged. | Rig/physics intent preserved as native `UsdPhysics`. |

**Default deliverable = A.** It is exactly PRD §5.3 ("open the door — proper Xform ops on that prim"): standard Xform ops plus one custom string attribute, RealityKit/QuickLook-clean, undoable, and round-trip-safe through the *existing* serializer — no dependency on the variant-content bridge gap or the open time-sample round-trip gap. Open/close is a normal, undoable transform edit; the part ships in its `defaultState` (closed) pose with the mechanism described on the pivot for runtime tooling and the export-compliance layer.

B, C, and D are **profile-gated enhancements**, each flagged against the active export profile per Pillar 2 — never silently dropped:

- **B (state variants)** needs variant-scoped opinions, which the in-memory `VariantSet` projection does not model (it is set-name + variant-names + selection only; the USD stage is the source of truth via the bridge). So B is authored through the usd-core bridge, and — as its own reusable capability, useful for colorways/size options too — adds `CreateVariantSetCommand`/`AddVariantCommand` + a `variants.usda` round-trip fixture in `roundtrip-gate.sh`.
- **C** is gated on closing the `animated.usda` time-sample round-trip gap.
- **D** is gated on the physics export profile.

## MCP surface — so coding agents *know* they can do this

The whole point of the request: **a coding agent (Claude, via the `openusdz` MCP server) must be able to discover and build a fully hinged, swingable object.** Discovery is via `tools/list` descriptions + `prompts/list` workflow recipes (the only contract the server advertises). We add both.

### New tools (`AgentMCP`, group `.mutate`)

1. `create_variant_set { path, set, variants: [string], selection? }` — author a variant set with named (initially empty) variants; optional initial selection. *(Phase A)*
2. `add_variant { path, set, variant }` — add one variant to an existing set. *(Phase A)*
3. `create_joint { target, kind, axis:[x,y,z], pivot:[x,y,z], min, max, states:[{name,value}], defaultState }` — the headline tool. It:
   - inserts the `<target>_pivot` Xform between `target` and its parent (reusing `reparent_prim` semantics), origin placed at `pivot`;
   - offsets `target` so the closed pose leaves geometry in place;
   - authors representation **A** (a `state` variant set with each state's pivot transform) by default;
   - records the joint in the root's `sculptRuntime` manifest;
   - returns the pivot path, joint name, and authored states.
   Description explicitly says: *"Make a rigid part open/close/swing about a hinge axis (lid, door, cap, drawer). Authors portable open/closed states."*
4. `set_joint_state { target, state }` — select a joint's state (open/closed), or `{ target, value }` to author an arbitrary in-limit pose. Wraps `set_variant` / pivot-transform authoring.
5. *(Phase C)* `bake_joint_animation { target, from, to, startTime, endTime }` — author representation B time samples (gated on the round-trip gap; the tool refuses under the default profile with a clear message until the gap closes).

`set_transform` gains an **optional `pivot:[x,y,z]`** so off-origin rotation is expressible directly for one-off cases (composed into the matrix, or, under `full-USD`, emitted as explicit pivot op-order).

### New workflow prompt (`WorkflowPrompts.swift`)

`author-hinged-object` — the recipe that teaches the flow end-to-end. Draft text:

```
Make a rigid part of an object open, close, or swing (a lid, door, cap, drawer):
1. Identify the moving part (a prim) and its hinge: the AXIS it rotates about and a
   PIVOT point ON the hinge line (e.g. the rear edge of a lid), in the assembly root's frame.
   Use get_prim / query_scene to read the part's world bbox and pick the pivot on its edge.
2. Call create_joint { target, kind: "revolute", axis, pivot, min: 0, max: 105,
   states: [{name:"closed",value:0},{name:"open",value:105}], defaultState: "closed" }.
   This inserts a <target>_pivot Xform on the hinge line and authors portable
   open/closed states — no physics or animation needed for QuickLook/RealityKit.
3. Preview: set_joint_state { target, state: "open" } then render_views {}; flip back
   with state: "closed". Judge that the part swings about the correct edge, not its centre.
4. For a slider (drawer) use kind: "prismatic" with min/max in scene units along the axis.
5. Validate { } (zero new errors) and check_compliance { profile: "arkit" }
   (isExportAllowed must be true — state variants are ARKit-portable). Then save {}.
For an animated swing (not just discrete states), bake_joint_animation is available under
the full-USD profile; the default QuickLook profile ships discrete open/closed states.
```

The existing `sculpt-from-image` prompt's step 2 is extended: when the object has an obvious openable part, declare a `joint` in the spec so the `interaction` pass authors it.

## SculptKit integration

- `ObjectSculptSpec` gains `joints: [Joint]` (decode-defaults to `[]`, like every runtime-layer field — pre-articulation specs still load).
- The **`interaction` pass** authors joints (representation A) alongside sockets/colliders; `RuntimeManifest` carries an `articulations` list so downstream RealityKit tooling can discover openable parts.
- `SpecValidator`: joint refs valid (`target` is a real component; `axis` non-zero; `min<=max`; states in range and USD-valid; `{closed,open}` present; `defaultState` exists). Schema errors block.
- `SpecValidator.actionReady` recognizes a joint as an actionable runtime handle (today it requires a socket or collider; a joint should also satisfy it).

## Test & Invariant Harness (Phase T rule — same PR as each op)

`MechanismKit` carries a **100% coverage floor + fuzz corpus** (like MeshKit/RigKit):

- **Axis fixed-point** (fuzzed over random axes/pivots/values): points on the hinge line are invariant under the pose (ε-bounded).
- **Rest == closed**, **limit ordering**, **state-in-range**, **axis non-degenerate**, **determinism** — as listed under the data model.
- **Pivot-hierarchy correctness:** after `create_joint`, the closed pose reproduces the pre-joint world transform of `target` within ε (inserting the pivot must not move the geometry).
- **Variant round-trip** (`roundtrip-gate.sh`, new `mechanism.usda` fixture): author `{closed,open}` state variants → save → open preserves both variants and the selection.
- **Golden posed frames:** deterministic offscreen renders of closed vs. open (perceptual ΔE gate, per `specs/testing.md §7`).
- **Export-profile degradation snapshots:** what a joint bakes to under RealityKit/QuickLook vs. full-USD (Phase 12's degradation-snapshot pattern) — A preserved, B gap-flagged, C baked/flagged.
- **MCP contract test:** `create_joint` → `set_joint_state open` → `render`/`raycast` confirms the moving part changed pose about the correct axis; `validate` clean; `check_compliance` `isExportAllowed == true`.

## Phasing

- **Phase B — mechanisms (headline, the default path).** ✅ Shipped: `MechanismKit` module (data + pivot math + invariants, 100% coverage + fuzz corpus); `CreateJointCommand`/`SetJointStateCommand` in EditingKit (representation A — pivot Xform + `mechanism:joint`, undoable, round-trip-safe); `create_joint`/`set_joint_state` MCP tools; `author-hinged-object` workflow prompt. Remaining in-phase: SculptKit `joints` + interaction-pass authoring; optional `set_transform` `pivot` convenience.
- **Enhancement — state variants (representation B).** Bridge-authored variant-scoped poses so both states ship switchably: `CreateVariantSetCommand`/`AddVariantCommand` in EditingKit + `create_variant_set`/`add_variant` MCP tools + a `variants.usda` round-trip fixture. Independently useful (colorways, size options).
- **Enhancement — baked swing animation (representation C).** Gated on closing the time-sample round-trip gap (`animated.usda`). `bake_joint_animation` tool.
- **Enhancement — physics joints (representation D).** `UsdPhysics` revolute/prismatic authoring for the interactive/full-USD profile + degradation to A.

> Phase B was built first (not a prerequisite "Phase A") precisely because representation A carries the whole capability with no dependency on the variant-content bridge gap — the enterprise-grade, PRD-aligned default. The variant/animation/physics enhancements layer on without blocking it.

## Console & CLI parity

Per the Continuous/Platform roadmap: every articulation op is scriptable through the injected `app.*` API with single-undo script runs, reachable from the ⌘K command palette via `ActionRegistry`, and batchable as a CLI subcommand (consistent with `convert`/`validate`/`recolor`).
</content>
</invoke>
