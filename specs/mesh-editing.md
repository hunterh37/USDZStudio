# Mesh Editing Specification — MeshKit & Component-Level Ops (MVP+)

## Scope Statement

Targeted mesh **repair and adjustment** — not modeling-from-scratch. The mission use cases: add a mounting tab to a bumper (extrude), thicken a flat panel (extrude/solidify), close a hole (fill), clean vendor-mesh defects (merge/delete), soften a hard edge (bevel). Sculpting, subdivision-surface modeling, booleans, and retopology remain non-goals permanently.

Designed explicitly to be **built and verified by LLM code agents**: every operation is a pure function on value types with machine-checkable correctness invariants — no human eyeball required to know an op is right.

## New Package: MeshKit

```
MeshKit (pure Swift, zero dependencies, 100% coverage tier)
├── HalfEdgeMesh          # core topology structure
├── MeshIO                # USD flat arrays ⇄ half-edge (lossless attribute round-trip)
├── Ops/                  # one file per operation, pure functions
│   ├── ExtrudeFaces.swift
│   ├── InsetFaces.swift
│   ├── DeleteComponents.swift
│   ├── MergeVertices.swift     # by distance + explicit target
│   ├── FillHole.swift          # boundary-loop triangulation
│   ├── BevelEdges.swift        # single-segment v1, strict preconditions
│   └── LoopCut.swift           # quad-strip traversal, v1.5
└── Invariants            # shared validation used by ops and tests
```

Dependency position: `EditingKit ─▶ MeshKit`, `ViewportKit ─▶ MeshKit` (component overlay rendering). MeshKit imports nothing from the app.

### HalfEdgeMesh
- Value-semantic (`struct`, CoW) — enables snapshot-based undo and safe concurrency.
- Stable component IDs across ops (required for selection persistence and undo).
- Attribute channels carried through topology changes: positions, normals (with seam/crease preservation), UV sets, GeomSubset face membership, skin weights (v1: ops **refuse** on skinned meshes with a clear diagnostic; weight propagation is a later tier).
- `MeshIO` round-trip is bit-faithful for untouched regions: import → export with no ops = identical USD arrays (CI invariant).

### Operation contract

```swift
public protocol MeshOp {
    associatedtype Params
    /// Pure: no side effects. Throws typed MeshOpError with precondition diagnostics.
    static func apply(_ mesh: HalfEdgeMesh, selection: ComponentSelection, params: Params)
        throws -> MeshOpResult   // new mesh + result selection + topology delta report
}
```

Every op documents and enforces **preconditions** (e.g. Bevel: manifold edges only, no adjacent selected edges in v1) — failing loudly with an actionable message beats silently producing garbage. Precondition checks are themselves tested.

## v1 Operation Set (in build order)

| Op | Semantics (Blender-equivalent) | Predicted topology delta (tested) |
|---|---|---|
| ExtrudeFaces | Extrude region along averaged normal or axis | V+=boundaryV, E+=boundaryE+boundaryV, F+=boundaryE |
| InsetFaces | Per-face or region inset | analytic per region |
| DeleteComponents | Delete faces / edges+adjacent / verts+adjacent | analytic |
| MergeVertices | By distance threshold or to active vert | analytic |
| FillHole | Fan/ear-clip triangulate a boundary loop | F+=n−2, E+=n−3 |
| BevelEdges (v1) | Single-segment edge bevel, uniform width | analytic per edge class |
| LoopCut (v1.5) | Insert edge loop through quad strip | analytic; op refuses on non-quad strips |

## Correctness Invariants (the LLM-agent feedback loop)

Checked by every op's test suite and available as a debug assertion after every op in dev builds:

1. **Euler characteristic** V−E+F changes by exactly the op's predicted delta.
2. **Manifoldness preserved** (every edge ≤ 2 faces; no isolated verts unless op documents them).
3. **Winding consistency** — adjacent faces agree on orientation; signed volume sign preserved.
4. **No degenerates** — zero-area faces / zero-length edges / duplicate face verts forbidden.
5. **Analytic geometry checks** — cube face extruded by h: volume increases by exactly area×h; inset by d: new face area matches closed form (ε tolerance).
6. **Attribute integrity** — UV/subset/normal channels present before = present after; untouched faces byte-identical.
7. **Property-based fuzzing** — generated meshes (random manifold quads/tris, degenerate-adjacent cases) × random valid selections × random params: invariants 1–6 must hold or the op must have thrown a precondition error. No third outcome.
8. **Round-trip** — op → USD export → reimport → identical topology; op → undo → identical to original mesh (hash-compared).

Golden-mesh fixtures (committed .usda) cover the known nasty cases: bowtie verts, mixed tri/quad regions, UV seams crossing selection boundaries, subset borders.

## Editor Integration

### Component mode
- Toolbar mode toggle: **Object mode** (existing prim editing) ⇄ **Edit mode** (Tab, on a selected mesh prim) with vertex/edge/face sub-modes (1/2/3 keys — Blender muscle memory).
- Viewport overlays: vertex dots, edge lines, face-center dots; hover highlight; screen-space edge picking (distance-to-segment in NDC); box select in edit mode.
- Overlay rendering: dedicated Metal pass over the RealityKit frame (same infrastructure as the selection outline).
- Ops invoked via toolbar buttons, menu, ⌘K palette, and hotkeys (E extrude, I inset, X delete, M merge, F fill). Params in a transient HUD panel (numeric entry, live-preview slider) — commit = one undo step.

### Undo & commands
- `MeshEditCommand` wraps a `MeshOp`: undo restores the prior `HalfEdgeMesh` snapshot (CoW makes this cheap); redo re-applies deterministically. Stage write happens on commit: mesh exported to USD arrays → `SetAttributeCommand` batch on points/indices/normals/uvs.
- Edit-mode session keeps the working half-edge mesh in memory; leaving edit mode (or saving) flushes to the stage. Crash journal stores the op list.

### Skinned/animated meshes
- Edit mode disabled with an explanatory badge ("mesh has skeletal binding — mesh editing would break weights"). Explicit non-silent refusal, per app philosophy.

## Testing (extends specs/testing.md)

| Layer | Gate |
|---|---|
| MeshKit unit + property tests | **100% coverage**, fuzz corpus in CI, invariant suite mandatory per op |
| Golden meshes | topology + attribute snapshots reviewed in PR |
| Integration | edit-mode session → save → reopen → ComplianceChecker + usddiff clean |
| UI | XCUITest: tab into edit mode, extrude, undo, export; golden-image overlay rendering |

## Build Order (maps to roadmap Phase 6)

1. HalfEdgeMesh + MeshIO + invariant suite (the foundation — get this bulletproof first)
2. DeleteComponents, MergeVertices (simplest ops, validate the pipeline end-to-end)
3. ExtrudeFaces, InsetFaces, FillHole
4. Component-mode UI (selection, overlays, HUD) — highest human-review budget here
5. BevelEdges (single-segment) — last, most edge cases
6. LoopCut + param polish (v1.5 follow-up)
