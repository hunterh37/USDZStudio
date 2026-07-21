# Staged-Sculpt Pipeline (SculptKit + AgentMCP `.sculpt`)

Reconstruct a reference image as a **native USD object** through a staged,
quality-gated pipeline modeled on [img2threejs](https://github.com/hoainho/img2threejs).
The design principle is the same: **deterministic code does all mechanical
work; the agent spends tokens only on visual pass/fail judgment.** The only
difference is the output — a USD stage authored through the existing
`EditSession` funnel instead of Three.js TypeScript.

## Module split

- **`SculptKit`** (pure logic, deps `USDCore` + `MeshKit`, 100% floor): the
  spec model, detail inventory, pre-spec assessment, strict-quality validator,
  the locked-pass state machine, and the per-pass build planner. It authors no
  stage itself — it emits declarative `BuildStep`s.
- **AgentMCP `.sculpt` tool group** (`Tools+Sculpt.swift`): thin handlers that
  drive `SculptKit` and realize `BuildStep`s through `EditSession.mutate`,
  reusing `MutateTools.makeInsert`, `GeometryProbe.meshAttributes`,
  `MeshIO.flat`, `ShapeLibrary`, `CreateMaterialCommand`, and
  `SetTransformCommand`. Cross-call state lives in the `SculptStore` actor.

## ObjectSculptSpec

The USD-native analog of img2threejs's spec (`ObjectSculptSpec.swift`):

- `root: ComponentNode` — a tree; each node has a `shape`
  (`group` | `primitive(plane|box|cylinder|cone|sphere)` |
  `library(entryID)` referencing a `MeshKit.ShapeLibrary` prefab), a local
  TRS, parametric dimensions, an optional `materialID`, an optional
  `RepetitionSystem`, and children.
- `materials: [MaterialSpec]` — channel-independent PBR (baseColor, roughness,
  metallic, optional emissive) plus optional **texture channels** (`albedoMap`,
  `normalMap`, `roughnessMap`, `emissiveMap` asset-path strings and a
  `normalScale`). Every map field is optional and decode-defaulted so specs
  authored before texture support still load; the material pass authors the
  declared maps as extra shader inputs, not just a flat colour.
- `surfaceProjection: SurfaceProjection?` — optional projected-texture /
  de-light descriptor (a `CameraPose` + target UV set + target component +
  `delight` flag) realized by the surface pass. Decode-defaults to nil.
- `landmarks: [Landmark]` — proportion-lock anchors (name + component +
  position). Required for `.character` specs; decode-defaults to `[]`.
- `lights: [LightSpec]` — real `UsdLux` lights authored by the lighting pass
  (`distant|sphere|rect|dome`, intensity, colour, transform). Decode-defaults
  to `[]`.
- `lodTiers: [LODTier]` — level-of-detail tiers (name + screenCoverage +
  decimation) authored by the optimization pass. Decode-defaults to `[]`.
- each `ComponentNode` carries an optional `attachment`
  (`root|weld|socket|pin|free`) declaring how it joins its parent — the
  attachment-correctness gate rejects geometry leaves that are unspecified or
  `.free`. Decode-defaults to nil.
- `DetailItem` gains an optional `minScore` — the per-feature acceptance
  threshold enforced by the feature-acceptance gate.
- `sockets: [Socket]` — named attachment points for rigging/props.
- `colliders: [Collider]` — runtime collision volumes (`box|sphere|capsule|convexHull`)
  wrapping a named component. Part of the action-ready runtime layer.
- `destructionGroups: [DestructionGroup]` — named component groups that break
  away together at runtime.
- `detailInventory: DetailInventory` — the detail-first feature list.
- `reviewHistory: [PassReview]` — every pass's recorded decision + evidence.

`RepetitionSystem` supports three layouts via `kind`: `linear` (offset by
`step * i`), `radial` (revolved around `axis`, default +Y, using Rodrigues
rotation of `step`), and `grid` (a `gridCounts` = [nx, ny, nz] lattice spaced by
`step`). Legacy specs without `kind` decode as `linear`; the new spec fields all
decode-default so pre-runtime-layer specs still load.

The spec is `Codable`; the `.sculpt` tools persist it to
`<workDirectory>/sculpt-spec.json` between calls.

## Detail inventory (detail-first)

`DetailInventory` enumerates identity-defining features
(`bevel|gloss|linework|wear|screw|seam|emissive|other`) **before** geometry is
authored. Each `DetailItem` is *mapped* once it names the component or material
that realizes it. The strict-quality gate blocks any spec with unmapped items.

## The eight locked passes

In strict order (`SculptPass`): `blockout → structural → formRefinement →
material → surface → lighting → interaction → optimization`. A pass unlocks
only after the previous is accepted. Six passes author into the stage;
`formRefinement` alone remains review-only:

| Pass | Authors |
|------|---------|
| blockout | Coarse geometry for every node + repetition copies (real prims). |
| structural | `set_transform` placement for every authored prim. |
| material | `create_material` for each painted node, plus the extra PBR channels (roughness/metallic scalars, emissive, and any texture maps + normalScale) as shader inputs on the created surface. |
| surface | Authors a projected-texture / de-light descriptor (`sculptProjectedTexture` string attribute on the root) when the spec declares a `surfaceProjection` targeting a real component. |
| lighting | Authors a real `UsdLux` light prim (with `inputs:intensity` + `inputs:color`) plus its placement for each declared `LightSpec`, under the sculpt root. |
| interaction | Authors the action-ready runtime manifest (`sculptRuntime` string attribute on the root) when the spec exposes a socket or collider. |
| optimization | Authors the LOD manifest (`sculptLOD` string attribute on the root) when the spec declares `lodTiers`. |
| formRefinement | Review-only (no mutations). |

The surface pass mirrors img2threejs's `bake_projected_texture` +
`delight_albedo`: SculptKit emits only the declarative descriptor (camera pose
+ target UV set); the executors realize it, so SculptKit performs no image
processing and stays a pure leaf.

## Gates

1. **Suitability gate** (`PreSpecAssessment.assess`): every assessment carries a
   `SuitabilityVerdict` — `viable`, `needsMoreInput` (no hints, or a
   single-hint character), or `rejected` (reference smaller than 64px per side).
   Surfaced by `sculpt_assess` so the agent can gather more or halt before
   authoring.
2. **Strict-quality gate** (`SpecValidator`, `strictQuality: true`): schema
   validity **plus** — relative to the `PreSpecAssessment` policy — full detail
   mapping, minimum detail-item count, minimum component count, and material
   coverage of geometry leaves. Blocks before any build pass. Runtime-layer
   references (collider components, destruction-group members) are schema-checked
   on every validate. Material texture channels are schema-checked too (map
   paths must be non-empty; `normalScale >= 0`), as is the `surfaceProjection`
   (target component must exist, `uvSet` non-empty, camera vectors `[x,y,z]`)
   and each `landmark` (component must exist, position `[x,y,z]`). The
   strict-quality gate additionally requires that a `.character` spec declare at
   least one proportion-lock landmark, keeping character proportions
   deterministic across rebuilds.
3. **Continue gate** (`PassOrchestrator.advance`): `continue` requires a
   render, a comparison sheet, **and** a vision score ≥ the assessed threshold
   (`policy.minScore`). Missing evidence or a low score is rejected.
4. **Action-ready gate** (`SpecValidator.actionReady`): the `interaction` build
   pass is rejected unless the object exposes at least one socket or collider,
   mirroring img2threejs's requirement that the finished object carry a usable
   runtime layer.
5. **Attachment-correctness gate** (part of strict-quality): every geometry
   component other than the root must declare an `attachment` and it must not be
   `.free` — img2threejs's "declare a join method; nothing floats mid-air".
   Groups and the root are exempt.
6. **Feature-acceptance gate** (`SpecValidator.featureAcceptance`): a `continue`
   out of the final pass must clear every per-feature `minScore`. `sculpt_review`
   records per-feature scores via its optional `featureScores` map, mirroring
   img2threejs's `feature_acceptance_policy`.

Light and LOD schema (unique valid names, finite non-negative intensity, RGB
colour in 0...1, screenCoverage in 0...1, decimation in (0, 1]) is checked on
every validate. A `sculpt_probe` intake step vets technical fitness (usable /
marginal / unusable, plus a recommended component ceiling) from image
dimensions before assessment.

## Review-loop contract

After each pass the agent records one `PassDecision`:
`continue | refineSpec | refineCode | requestInput | stop` — the img2threejs
contract exactly. `continue` unlocks the next pass (or completes the object);
`refineSpec`/`refineCode` keep the pass unlocked to fix the spec or rebuild;
`requestInput` pauses; `stop` halts.

## Tool surface (`mcp__openusdz__*`)

`sculpt_probe` (optional intake vet) → `sculpt_assess` → `sculpt_author_spec` → `sculpt_validate_spec` →
per pass: `sculpt_build_pass` → `render_views` → `sculpt_comparison_sheet`
(composes the reference-vs-render SVG sheet into the work directory) → `score`
→ `sculpt_review` (fed the sheet path + fidelity score); `sculpt_status` reports
state (current pass, socket/collider counts, action-ready flag) at any point. The `sculpt-from-image` workflow
prompt scripts the whole loop. Image→base-mesh generation, when wanted, plugs
in via the existing `generate_asset`/`fetch_asset` `AssetGenerating` seam
without changing SculptKit.

## Testing

SculptKit and the `.sculpt` handlers are both held to the 100% logic floor
(`scripts/coverage-gate.sh`). The genuinely-defensive command-construction
catches in `Tools+Sculpt.swift` carry `// coverage:disable` with a rationale,
matching the rest of AgentMCP.
