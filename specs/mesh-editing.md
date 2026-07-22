# Mesh Editing Specification — MeshKit & Component-Level Ops (MVP+)

## Scope Statement

Targeted mesh **repair and adjustment** — not modeling-from-scratch. The mission use cases: add a mounting tab to a bumper (extrude), thicken a flat panel (extrude/solidify), close a hole (fill), clean vendor-mesh defects (merge/delete), soften a hard edge (bevel), and **directly nudge vertices** — a live vertex edit mode with proportional (soft-selection) falloff, scaling to million-vertex meshes (see §Live vertex edit). Subdivision-surface modeling, booleans, retopology, and voxel/remesh sculpting engines remain non-goals; brush-style sculpt tools (grab/inflate/smooth) are a permitted future extension of the live-vertex machinery.

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
| SubdivideCatmullClark | Whole-mesh Catmull-Clark smoothing (n levels) | per level: V+=E+F, E+=E+C, F+=C−F (C=Σ loop.count) |

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
- Edit-mode session keeps the working half-edge mesh in memory; leaving edit mode (or saving) flushes to the stage. `MeshEditSession` keeps its own in-session op list for the label on commit; crash safety itself is handled one level up by the app-wide command write-ahead log (specs/editing-model.md §Dirty State & Saving), which captures the committed `MeshEditCommand` like any other command.

### Skinned/animated meshes
- Edit mode disabled with an explanatory badge ("mesh has skeletal binding — mesh editing would break weights"). Explicit non-silent refusal, per app philosophy.

## Live vertex edit

A component edit mode (vertex sub-mode, hotkey `1`) that shows the vertex/edge point cloud over the mesh and lets the user click-drag points to deform it live, at the million-vertex scale.

### Kernel (MeshKit, pure)
- `SetVertexPositions` op — absolute per-vertex position setting, `Params { positions: [VertexID: SIMD3<Double>] }`, `TopologyDelta (0,0,0)`. Rejects non-finite coordinates explicitly (a NaN passes both `< lo` and `> hi` range checks, so it is guarded at the boundary) and unknown vertices; the shared `OpSupport.verify` still rejects moves that collapse a face. The interaction layer computes final absolute positions; the op stays free of UI concepts.
- `ProportionalFalloff` — pure geodesic soft-selection: given seeds, a radius and a curve (`constant/linear/smooth/sphere`), returns `[VertexID: Double]` weights via Dijkstra over edge lengths. The drag layer multiplies weight × drag-delta into each vertex's base position.

### Rendering (ViewportKit, macOS 15+)
- `LiveMeshRenderer` backs the edited prim with a `LowLevelMesh` (shared vertices + a smooth normal buffer — not `MeshFlattener`'s per-face duplication). A drag rewrites only the moved vertices' slots and their 1-ring normals in place (`LiveMeshBuffers.applyPositionChanges`), never regenerating the `MeshResource`. The CPU-side buffer math is pure and unit-tested; the `LowLevelMesh` submission is GPU glue (coverage-excluded, golden-image-tested).
- `VertexAccelerator` — a vertex BVH (sibling of `PickAccelerator`) for nearest-vertex picking and rectangle/lasso region select, culling whole nodes by projected screen bounds (O(visible), not O(n)).
- `OverlayLOD` — deterministic stride decimation of the vertex-dot overlay to a hard cap (selected/hovered always drawn), recomputed on camera-settle, so a million dots never render at once.
- Scene seam: `SceneGraphOperation.updateVertices(path, positions)` is emitted by `SceneGraphDiff` when a survivor prim's positions change on identical topology (`ViewportMeshData.positionChanges`), reserving full `.updateMesh` for topology changes. The interactive drag bypasses the ViewportScene round-trip and writes `LiveMeshRenderer` directly; `.updateVertices` serves the programmatic/MCP/undo path.

### Interaction & undo
- Preview lives in the GPU buffer only; the `HalfEdgeMesh`/session is untouched until mouse-up. On mouse-up a single `SetVertexPositions` op → `MeshEditSession.record` → one coalesced `MeshEditCommand` (before/after `FlatMesh`) = one undo step, exactly like the extrude gizmo's "a gesture produces zero or one op" invariant. Skinned meshes keep the existing refusal.

### RealityKit export profile
- A pure vertex move authors only the `points` array — RealityKit-clean, no blocking diagnostics under `arkit`/`arkit-strict`, and it degrades trivially (nothing to strip).

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

## Lattice deformer (FFD cage)

Free-form deformation (Sederberg & Parry, SIGGRAPH 1986): wrap a selected mesh in an oriented `l×m×n` grid of control points and re-evaluate every vertex through a trivariate tensor product of the displaced control points, smoothly deforming the enclosed geometry. Object-level (deforms the whole mesh, not a component sub-selection), non-destructive until commit. Research + rationale: `research/topics/lattice-deformer/`.

### Model (MeshKit — pure, 100% coverage)
- `LatticeCage` (`Deformers/LatticeCage.swift`): oriented rest frame (`origin`, `edgeS/T/U`), `Resolution` (2…8 per axis), `Interpolation { trilinear, cubicBSpline }`, `affectOutside`, row-major `controlPoints`. `bind(points:)` caches each vertex's `(s,t,u)` local coordinate (scalar-triple-product solve) + rest position; `deform(_:)` re-evaluates the tensor product against the current control points.
- `FFDBasis` (`Deformers/FFDBasis.swift`): per-axis samplers. Trilinear = degree-1 (C⁰, "Linear Sharp"); cubic B-spline = C² ("Cubic"), with **linearly-extrapolated phantom border nodes** so both bases have linear precision (a rest cage reproduces its input exactly; a `2×2×2` cage reproduces any affine map exactly).
- `LatticeDeform` op (`Ops/LatticeDeform.swift`): validates the cage, bakes positions, guards non-finite results, and runs the shared invariant check (topology delta must be zero — FFD is purely positional). Added to the `FuzzCorpus` sweep.

### Command (EditingKit — 100% coverage)
- `LatticeDeformCommand.make(path:cage:in:)` reads the prim geometry, routes through the MeshKit op, recomputes area-weighted vertex normals for the deformed surface, and captures the prior `points`/`normals` for an exact `AttributeUndo` inverse. Refuses non-mesh prims, skinned meshes (would desync skin weights), missing/malformed geometry, and degenerate cages. `execute`/`undo` author/restore `points` (+ `normals`) as one coalesced step.

### Editor integration
- `EditorDocument+Lattice.swift`: `toggleLatticeMode` (⇧⌘L or command palette) descends to the first editable mesh and fits a padded rest cage to its **prim-local** bounds (same space as the extrude gizmo's prim-local ray — no world-matrix math). Panel controls set resolution (refits, resets deformation — Blender parity), interpolation basis, and affect-outside; Reset restores the rest cage. Commit bakes one undoable `LatticeDeformCommand`; cancel discards.
- `LatticeCageGizmo` (ViewportKit): control-point handle hit-test (reuses `ExtrudeGizmoMath` ray/segment math), grid wireframe edge set, and camera-facing-plane free-drag delta. `LatticeOverlay` (EditorUI) is the parameter HUD around the gizmo.

### RealityKit export profile
- The bake authors only `points` + recomputed `normals` — ordinary mesh data, RealityKit-clean, no blocking diagnostics under `arkit`/`arkit-strict`, nothing to strip. The cage is authoring-only session state and is **never serialized** (there is no USD lattice schema), which is the correct lossless behavior for the deformed result.
