# Implementation Plan — Lattice / FFD Cage Deformer

- **Slug:** `lattice-deformer` (pairs with `research.md` in this folder)
- **Date:** 2026-07-21
- **Source research:** `./research.md`
- **Roadmap slot:** Post-1.0 authoring spine, **Phase 8 (full mesh modeling)**, as a self-contained extension of `specs/mesh-editing.md` §Live vertex edit. Depends on: MeshKit half-edge/`MeshIO` (landed), the shared transform-gizmo seam (Milestone 1, landed), the area-weighted normal synthesis quick-fix (Milestone 5, landed). Unblocks: cage-based reshaping of vendor meshes (bulge/taper/bend) without per-vertex nudging. Independently shippable — no other Phase 8 item gates it.
- **Status:** proposed

## Summary

Add a **contained lattice deformer**: with a mesh prim selected, the user enters *Lattice mode*, an `l×m×n` box of control-point handles appears around the object's oriented bounds, and dragging handles smoothly deforms the enclosed geometry via free-form deformation (trilinear or cubic B-spline). Commit **bakes** the deformed vertices into the mesh `points` attribute as one coalesced undo step and re-synthesizes normals; cancel restores the rest mesh. The cage is authoring-only session state — never written to USD — so the exported result is an ordinary mesh that is fully valid under the RealityKit `arkit` export profile. It reuses the existing gizmo, overlay, command, and normal-synthesis infrastructure; it adds **no new package**.

## Module targets

| Module (`Packages/*`) | Change | New dependency edges | Legal per architecture.md? |
|---|---|---|---|
| **MeshKit** | New `Deformers/LatticeCage.swift`, `Deformers/LatticeBinding.swift`, `Deformers/FFDBasis.swift` — pure FFD math (bind + deform). Extend `Invariants` with FFD checks. | none (stays pure, zero internal deps) | yes — MeshKit imports nothing internal; framework ban still honored (no UI/GPU/Python). |
| **EditingKit** | New `Commands/LatticeDeformCommand.swift`; `MeshEditSession` gains a lattice sub-mode holding the working `LatticeCage` + `LatticeBinding`. | → MeshKit (existing edge) | yes — `EditingKit ─▶ MeshKit` is an existing rule. |
| **ViewportKit** | New `Gizmos/LatticeCageGizmo.swift` (handle dots + cage wire in the existing Metal overlay pass); hit-test/drag routed through the shared gizmo seam. | → MeshKit (existing edge) | yes — `ViewportKit ─▶ MeshKit` is an existing rule. |
| **EditorUI** | New `Lattice/LatticePanel.swift` + `LatticePanelModel` (`@Observable @MainActor`); toolbar/⌘K entry; edit-mode toggle. | → EditingKit, ViewportKit, DesignSystem (existing) | yes — EditorUI already depends on all kits + DesignSystem. |

> No package added ⇒ no `dependency-lint.sh` / `module-governance.sh` entry needed. All four edges are pre-existing one-directional rules in `specs/architecture.md`. `specs/mesh-editing.md` gains a §Lattice deformer section in the build PR.

## Data model / API

```swift
// ── MeshKit (pure, Sendable, 100% coverage tier) ────────────────────────────
public struct LatticeCage: Sendable, Equatable {
    public enum Interpolation: Sendable { case trilinear, cubicBSpline }
    public struct Resolution: Sendable, Equatable {   // control points per axis, ≥2, ≤8
        public var l, m, n: Int
    }
    /// Oriented rest frame: local (s,t,u) ∈ [0,1]³ maps into this parallelepiped.
    public var origin: SIMD3<Float>              // X0 (min corner)
    public var edgeS, edgeT, edgeU: SIMD3<Float> // spanning vectors (need not be axis-aligned)
    public var resolution: Resolution
    public var interpolation: Interpolation
    public var affectOutside: Bool               // false ⇒ clamp (s,t,u) to [0,1]
    /// Row-major (l·m·n) grid; controlPoints[i + l*(j + m*k)]. Rest grid == regular lattice.
    public var controlPoints: [SIMD3<Float>]

    /// Regular cage sized to an oriented bounding box, all control points at rest.
    public static func fitted(toOrientedBounds: OrientedBounds,
                              resolution: Resolution,
                              interpolation: Interpolation) -> LatticeCage
    /// Cache each vertex's local (s,t,u) + enclosing-cell indices against the REST cage.
    public func bind(points: [SIMD3<Float>]) -> LatticeBinding
    /// Pure re-evaluation of the tensor product with the CURRENT controlPoints.
    public func deform(_ binding: LatticeBinding) -> [SIMD3<Float>]
}

public struct LatticeBinding: Sendable, Equatable {   // opaque cached parameters
    // per-vertex (s,t,u) and, for cubicBSpline, the base cell index; count == points.count
}

// ── EditingKit ──────────────────────────────────────────────────────────────
public struct LatticeDeformCommand: EditCommand {   // coalesced, undoable
    public let primPath: PrimPath
    public let deformedPoints: [SIMD3<Float>]        // baked result
    public let synthesizedNormals: [SIMD3<Float>]?   // area-weighted recompute
    // execute(): SetAttributeCommand batch on points (+ normals); undo(): restore snapshot.
}
```

## Algorithm

**Frame + local coordinates (bind, once on entry).** Build `X0, S, T, U` from the prim's oriented bounds. For each vertex `P` solve for `(s,t,u)` via the scalar-triple-product form (numerically stable, no matrix inverse):

```
den_s = dot(cross(T,U), S)                 // = signed cage volume component; guard |den| > ε
s = dot(cross(T,U), P − X0) / den_s
t = dot(cross(S,U), P − X0) / dot(cross(S,U), T)
u = dot(cross(S,T), P − X0) / dot(cross(S,T), U)
```

If `affectOutside == false`, clamp each of `s,t,u` to `[0,1]` before caching (points outside the cage stay put). Cache `(s,t,u)` for trilinear; for cubic B-spline also cache the base cell so the 4-tap-per-axis window is stable under edits.

**Deform (per edit, O(verts)).** With control grid `Pᵢⱼₖ` (`i∈0..l-1` etc.):

```
P' = Σ_i Σ_j Σ_k  Bᵢ(s)·Bⱼ(t)·Bₖ(u)·P[i,j,k]
```

- **trilinear:** degree-1 — only the 8 corners of the enclosing cell contribute; `Bᵢ(s) = (1−s')` / `s'` where `s'` is the fractional coordinate within the cell (`s·(l−1)` split into integer cell + fraction). C^0.
- **cubicBSpline:** uniform cubic B-spline basis over the 4×4×4 window around the base cell (clamped at borders). C^2, smooth across cells. Weights from the standard `[ (1−t)³, 3t³−6t²+4, −3t³+3t²+3t+1, t³ ] / 6` window.

Rebuild is embarrassingly parallel; a serial loop is fine at repair scale (dispatch over `points` only if profiling demands it — still deterministic).

**Commit.** `deformedPoints = cage.deform(binding)`; recompute area-weighted vertex normals (reuse Milestone-5 synthesis); emit `LatticeDeformCommand` → one coalesced `SetAttributeCommand` batch on `points` (+ `normals`). **Cancel** discards session state; stage untouched.

**Edge cases / precision.** USD floats are 32-bit — do FFD math in `Float`, matching the stage. Degenerate cage edge (`|den| ≤ ε`) → throw a typed precondition error (never divide). Skinned/animated mesh → refuse with the standard explanatory badge (deforming baked points would desync skin weights), mirroring existing mesh-op refusals. Non-manifold/loose geometry is fine — FFD is purely positional and topology-preserving (Euler characteristic unchanged: this is an *invariant*, below).

## RealityKit export-profile behavior

The deformer produces only moved vertices + recomputed normals in the mesh `points`/`normals` attributes — standard `UsdGeomMesh` data. Under `arkit`/`arkit-strict` there is **nothing to flag or drop**: `ExportGate`/`ComplianceChecker` see an ordinary mesh. The cage is session-only authoring state and is never serialized (no USD lattice schema exists), so there is no non-portable prim to degrade. "What you see is what a user's RealityKit app renders" holds exactly, because the bake happens before export.

## Harness (lands in the SAME PR)

- **Invariants (MeshKit, property-based over `FuzzCorpus` + generated cages):**
  1. **Topology unchanged** — V−E+F identical before/after (FFD is positional): Euler characteristic delta == 0.
  2. **Rest-cage identity** — `deform(bind(P))` with control points at rest == `P` bitwise for trilinear, within ε for cubic (partition-of-unity ⇒ reproduces input). *Load-bearing correctness check.*
  3. **Affine reproduction** — a `2×2×2` cage transformed by any affine `M` yields `M·P` (trilinear reproduces affine exactly).
  4. **Partition of unity** — basis weights sum to 1 at every `(s,t,u)` (per-axis assertion across a sampled grid).
  5. **Outside-clamp** — with `affectOutside=false`, vertices with any coord ∉[0,1] are unmoved.
  6. **Determinism / round-trip** — deform → USD export → reimport → identical points; commit → undo → mesh hash-identical to rest.
- **Golden files:** committed `.usda` fixtures — cube under a known handle displacement (trilinear *and* cubic), and a taper case — asserted point-for-point within ε. Optional golden-image ΔE render of the deformed cube once the T1 offscreen harness is available (not a v1 blocker).
- **Unit tests + coverage:** MeshKit and EditingKit hold their **100%** floors (every basis branch, both interpolation modes, precondition throws, clamp on/off). ViewportKit/EditorUI additions covered under their current ratchet floors (raise, never lower).
- **Fuzz corpus:** extend `MeshKit/FuzzCorpus.swift` with random manifold meshes × random cage resolutions (2..8 per axis) × random handle displacements × both interpolation modes; invariants 1–6 must hold or a precondition error must be thrown — no third outcome (matches the existing mesh-op fuzz contract).

## Rollout

1. **MeshKit math first (harness-led):** `FFDBasis`, `LatticeCage.bind/deform`, invariants + fuzz. Green at 100% before any UI exists.
2. **EditingKit:** `LatticeDeformCommand` + `MeshEditSession` lattice sub-mode; round-trip + undo invariants.
3. **ViewportKit:** `LatticeCageGizmo` over the shared gizmo seam (handles, multi-select, cage wire); snapshot tests of cage layout per camera.
4. **EditorUI:** `LatticePanel` + toolbar/⌘K entry; wire enter/commit/cancel; skinned-mesh refusal badge.
5. **specs:** add §Lattice deformer to `specs/mesh-editing.md`; note the deferred Jacobian-normal-transport follow-up.

## Risks & open questions

- **Interpolation set for v1:** proposed trilinear + cubic B-spline (sharp mode is the free trilinear degenerate). Human sign-off if we want to ship trilinear-only first.
- **Cubic border handling:** clamped-window B-spline at cage borders (proposed) vs. natural end conditions — clamped is simpler and adequate; confirm.
- **Resolution cap:** proposed `≤8` per axis (Blender-like); confirm the ceiling.
- **Normals:** post-bake area-weighted recompute for v1; analytic Jacobian tangent transport (Heath's mode) deferred — needs human OK to defer.
- **Gizmo falloff:** Heath's proximity/soft-selection on handles is a nice-to-have; proposed for v1.5 once core cage editing is proven (the soft-selection machinery from §Live vertex edit can back it).

## Acceptance criteria

- [ ] `deform(bind(P))` at rest reproduces `P` (bitwise trilinear / ε cubic); affine reproduction exact for `2×2×2`.
- [ ] FFD preserves topology (Euler delta 0) across the full fuzz corpus, or throws a precondition error — no third outcome.
- [ ] Commit bakes deformed points as one coalesced undo step; undo restores a hash-identical rest mesh; export→reimport round-trips.
- [ ] Skinned meshes are refused with an explanatory badge (no silent breakage).
- [ ] MeshKit + EditingKit hold 100% coverage; ViewportKit/EditorUI ratchets held or raised.
- [ ] Deformed result exports clean under `arkit`/`arkit-strict` with nothing flagged (baked mesh only; no cage prim written).
