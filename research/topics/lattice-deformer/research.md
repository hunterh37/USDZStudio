# Research — Lattice / Free-Form Deformation (FFD) Cage

- **Slug:** `lattice-deformer`
- **Date:** 2026-07-21
- **Question:** How do modern DCCs/engines implement a lattice (FFD) cage deformer — the box-of-control-points gizmo that smoothly deforms an enclosed mesh — and what is the state-of-the-art, RealityKit-compatible way to build a *contained* version in OpenUSDZEditor?
- **Status:** planned
- **Related topics:** `../` mesh-editing (`specs/mesh-editing.md` §Live vertex edit — shares the proportional-falloff/soft-selection deformation lineage); transform gizmos (ROADMAP Milestone 1 — reuses the shared gizmo hit-test/drag seam).

## TL;DR

Lattice/FFD deformation is a 40-year-old, well-specified technique (Sederberg & Parry, SIGGRAPH 1986): wrap the mesh in a parallelepiped grid of control points and re-evaluate each vertex through a **trivariate tensor-product polynomial** in the lattice's local `(s,t,u)` coordinates. The state of the art (Blender `Lattice` object + `LatticeModifier`; Harry Heath's Unity *Lattice* asset) is exactly this, differing only in interpolation basis (trilinear vs. Catmull-Rom/cubic) and in whether evaluation runs on CPU or a compute shader. For us the right build is a **pure-Swift FFD deformer in MeshKit** (deterministic, 100%-coverage-friendly), driven by a **control-point cage gizmo in ViewportKit** (reusing the Milestone-1 gizmo seam) and an **undoable `LatticeDeformCommand` in EditingKit** that **bakes deformed points into the mesh `points` attribute on commit**. Baked vertices are trivially RealityKit-compatible; no custom USD schema and nothing to degrade under `arkit`.

## Comparison set

| Tool / source | How it solves this | Cost / complexity | License | Applicability to us |
|---|---|---|---|---|
| **Sederberg & Parry 1986**, "Free-Form Deformation of Solid Geometric Models" (SIGGRAPH; [DOI 10.1145/15922.15903](https://dl.acm.org/doi/10.1145/15922.15903)) | Embed mesh in a lattice; map each point to local `(s,t,u)∈[0,1]³`; deformed position = trivariate **Bernstein** tensor product of displaced control points | Math only; O(verts × (l·m·n)) per eval | n/a (paper) | **Adopt the math directly.** Bernstein gives global C^∞ smoothness; trilinear (degree-1 Bernstein) is the cheap special case. |
| **Blender** `Lattice` object + `LatticeModifier` (`source/blender/blenkernel/intern/lattice.c`, `latt_deform`) | Separate Lattice datablock with `pntsu/v/w` resolution; per-axis interpolation selectable **Linear / Cardinal / Catmull-Rom / BSpline**; binds by mapping vert into lattice space, weights from 1D basis per axis, tensor-combined | Mature, CPU (threaded), optional GPU in EEVEE draw path | **GPL-2.0+** | **Ideas/math only — no code.** Confirms the multi-basis design and the "separate cage object, bind on entry" UX. Clean-room the basis functions (standard, not Blender-specific). |
| **Harry Heath — Unity *Lattice*** ([harryheath.com/lattice](https://harryheath.com/lattice)) | FFD via configurable-resolution control-point grid; **compute-shader** deform; three modes *Linear Sharp / Linear Smooth / Cubic*; Position vs. Position+Normal+Tangent vs. Stretch; vertex/material masks; multiselect + proximity falloff on handles; Skinned (pre/post-skin) + Transform variants | Commercial, GPU compute | Proprietary | **UX north-star.** The gizmo interaction (multiselect, falloff, pivot/orientation modes, keyframe-able handles) is exactly the target from the user's screenshot. We cannot see its source; match the *behavior*, not the impl. |
| **Autodesk Maya** `lattice`/FFD deformer (docs) | Base-lattice + deformed-lattice pair; local ST/U basis; falloff, "outside lattice" modes | Mature | Proprietary | Confirms the **base-vs-deformed lattice** separation and the "affect points outside the cage" toggle (`Global` in Heath) as standard. |
| **usd-core / OpenUSD** | No native FFD schema. `UsdSkel` (skinning) and `PointBased.points` are the authoring surfaces; blendshapes store *offset* point sets | Apache-2.0 | Baseline reality | **Determines export:** there is no lattice prim to write. We **bake** the deformed `points` (RealityKit-safe), optionally keeping the cage in a non-exported edit session for re-editability. |
| **`MacCracken & Joy 1996`**, FFD with lattices of arbitrary topology ([DOI 10.1145/237170.237247](https://dl.acm.org/doi/10.1145/192161.192220)) | Catmull-Clark-style subdivision lattices, non-parallelepiped cages | Higher complexity | n/a (paper) | **Reject for v1** — arbitrary-topology cages are DCC surface-area we don't need; regular `l×m×n` box covers the use case. |

## State of the art

The technique is stable and identical in essence everywhere; the axes of variation are (1) **interpolation basis**, (2) **compute location**, (3) **what gets deformed** (positions only vs. normals/tangents too), and (4) **cage flexibility**.

**Core FFD math (Sederberg–Parry).** Establish a lattice local frame from an origin `X0` and three edge vectors `S, T, U` spanning the cage's oriented bounding box. For a world point `P`, its local coordinates are the solution of `P = X0 + sS + tT + uU`, i.e.

```
s = [T×U · (P−X0)] / [T×U · S]
t = [S×U · (P−X0)] / [S×U · T]
u = [S×T · (P−X0)] / [S×T · U]
```

with `(s,t,u) ∈ [0,1]³` for points inside the cage. Control points `Pᵢⱼₖ` form an `(l+1)×(m+1)×(n+1)` grid. The deformed point is the **trivariate tensor product**

```
P' = Σ_i Σ_j Σ_k  Bᵢ(s) · Bⱼ(t) · Bₖ(u) · Pᵢⱼₖ
```

where `B` is the chosen 1D basis. Two practical bases cover Heath's three modes:
- **Trilinear** (degree-1, weights `s`/`1−s` on the 8 enclosing corners): *Linear Sharp*. Cheapest; C^0 only → visible creases at cell boundaries when resolution > 1 per axis.
- **Cubic** (Bernstein for a full FFD volume, **or** Catmull-Rom / cubic B-spline sampled per-axis for local control): *Cubic* / *Linear Smooth*. C^1+, smooth across cells, ~4× the taps per axis.

Binding is done **once on entry**: compute and cache each vertex's `(s,t,u)` (and its enclosing-cell indices for the local-basis case) against the *rest* cage. Editing then only moves control points; evaluation re-runs the tensor product against cached parameters — O(verts) with a small constant, embarrassingly parallel.

**Normals/tangents.** Heath's "Position, Normal and Tangent" mode transforms the tangent basis by the deformation's Jacobian `∂P'/∂(s,t,u)` (analytic derivative of the same tensor product) rather than moving positions and recomputing face normals. For a repair-grade tool, recomputing area-weighted vertex normals after the bake (we already have this — the missing-normals quick-fix in Milestone 5) is a simpler, adequate substitute.

**Compute location.** Heath and modern EEVEE run the deform in a compute shader for live 60fps feedback on skinned characters. That is a *rendering-preview* optimization. For us the authoritative deform must be a **pure, deterministic CPU function** (coverage gate + round-trip determinism); a GPU preview kernel, if ever needed, is a parity-tested accelerator like the `RecolorEngine` Metal kernel (Milestone 6), not the source of truth.

## Recommended approach for OpenUSDZEditor

Build a **contained lattice deformer** as a mesh-editing tool, not a persistent scene object:

1. **`MeshKit/Deformers/LatticeCage.swift`** — pure value type: resolution `(l,m,n)`, oriented rest-bounds (`X0,S,T,U`), control-point positions `[SIMD3<Float>]`, and interpolation mode `{ .trilinear, .cubicBSpline }`. Pure functions: `bind(_ mesh:) -> LatticeBinding` (caches per-vertex `(s,t,u)` + cell indices) and `deform(_ binding:, points:) -> [SIMD3<Float>]`. Lives beside the live-vertex/soft-selection machinery; zero deps, 100% coverage.
2. **`EditingKit/Commands/LatticeDeformCommand.swift`** — enter lattice mode on a selected mesh prim → cage appears at the prim's oriented bounds → user drags control points → **commit** bakes `deform()` output into the `points` attribute via the existing `SetAttributeCommand` batch (one coalesced undo step), then re-synthesizes vertex normals. Refuses on skinned meshes with the same explanatory badge as other mesh ops.
3. **`ViewportKit`** — a `LatticeCageGizmo`: control-point handle dots + cage wireframe rendered in the existing Metal overlay pass (same as component overlays); hit-test/drag routed through the **shared gizmo seam from Milestone 1**, so translate/rotate/scale of selected handle sets, multi-select (shift/box), and pivot/orientation options come nearly for free.
4. **`EditorUI/LatticePanel`** — resolution steppers, interpolation-mode picker, "affect outside cage" toggle, Reset, and Commit/Cancel. `@Observable @MainActor` view model over an injected editing service.

Export is **baking**: the deformed `points` are ordinary mesh data, so the result is fully valid under `arkit`/`arkit-strict` with nothing to flag. The cage itself is authoring state held in the `MeshEditSession`; it is *not* written to USD (no lattice schema exists), which is the correct, lossless behavior.

### Rejected alternatives

- **Persist the lattice as a custom USD prim** (re-editable cage in the file) — no standard schema; would be dropped/flagged under `arkit` and is not portable to a user's RealityKit app. Baking is lossless for the *result*; re-editability lives in the session, not the export.
- **`UsdSkel`-based deformation** (treat cage corners as joints) — abuses skinning, needs weight authoring, and still bakes for AR. Far more surface area than trilinear FFD.
- **Arbitrary-topology / subdivision cages** (MacCracken–Joy) — general-DCC scope creep; a regular `l×m×n` box covers the screenshot use case.
- **GPU compute as the source of truth** (Heath's model) — violates the deterministic-CPU/coverage contract; permitted only later as a parity-tested preview accelerator.

## RealityKit / constraint reconciliation

- **Renderer:** the deform never touches RealityKit's shading — it moves vertices in the stage `points`, which RealityKit re-projects like any edit. No `ShaderGraphMaterial` dependency.
- **Overlay/gizmo:** cage lines + handles use the same Metal-over-RealityKit overlay pass already shipped for selection outlines and component overlays — no new rendering infrastructure.
- **Export profile:** baked points are the floor-compatible representation; `ExportGate`/`ComplianceChecker` see a normal mesh. Nothing degrades.
- **Module deps:** `MeshKit` stays pure (no UI/GPU/Python); `EditingKit → MeshKit` and `ViewportKit → MeshKit` edges already exist per `architecture.md`. No new package, so no `dependency-lint.sh`/governance addition.
- **Gap:** analytic Jacobian normal transport (Heath's tangent mode) is more than a repair tool needs; v1 recomputes normals post-bake and defers Jacobian transport as an optional follow-up.

## License & provenance notes

- **Blender** lattice code is **GPL-2.0+** — inspected only for design confirmation (separate cage datablock, selectable per-axis basis). We implement standard, textbook basis functions (Bernstein / cubic B-spline / Catmull-Rom) clean-room; **no Blender code copied**.
- **Harry Heath's Unity Lattice** is **proprietary**; used strictly as a UX reference (feature list from the public product page). No source access, nothing to copy.
- FFD math is from the **1986 Sederberg–Parry paper** (public technique, not copyrightable). Safe to implement.

## Open questions

- **Interpolation modes for v1:** ship trilinear + one smooth mode (cubic B-spline) — or trilinear only first and add smooth in v1.5? (Plan proposes trilinear + cubic B-spline; sharp mode is the free degenerate case.)
- **Default cage resolution:** Blender defaults `2×2×2` (corners only, = affine). Propose default `2×2×2` with steppers to `≤8` per axis; confirm the upper cap.
- **"Affect points outside cage":** clamp `(s,t,u)` to `[0,1]` (only inside deforms) vs. extrapolate the basis (global deform). Propose clamp-by-default with a toggle, matching Maya/Heath.
- **Normal handling:** post-bake area-weighted recompute (proposed) vs. analytic Jacobian transport (defer). Human sign-off on deferring.

## Sources

- Sederberg, Parry — "Free-Form Deformation of Solid Geometric Models," SIGGRAPH 1986 — https://dl.acm.org/doi/10.1145/15922.15903 (accessed 2026-07-21)
- MacCracken, Joy — "Free-Form Deformations With Lattices of Arbitrary Topology," SIGGRAPH 1996 — https://dl.acm.org/doi/10.1145/192161.192220 (accessed 2026-07-21)
- Harry Heath — *Lattice* (Unity asset) product page — https://harryheath.com/lattice (accessed 2026-07-21)
- 3D Free-form Deformation (WPI CS563 notes) — https://web.cs.wpi.edu/~matt/courses/cs563/talks/smartin/ffdeform.html (accessed 2026-07-21)
- Novedge — "Lattices, Cages, and Variational Methods: Evolution of FFD in CAD and DCC" — https://novedge.com/blogs/design-news/design-software-history-lattices-cages-and-variational-methods-evolution-of-free-form-deformation-in-cad-and-dcc (accessed 2026-07-21)
