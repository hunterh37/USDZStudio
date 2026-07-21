# Research — Gaussian Splatting & Real-World Capture → USDZ

- **Slug:** `gaussian-splatting-to-usdz`
- **Date:** 2026-07-21
- **Question:** Given that we ship mesh + `UsdPreviewSurface` USDZ and render through RealityKit, where does Gaussian Splatting (and real-world capture generally) actually fit our product — as a rendering feature, a reconstruction front-end, or a parallel representation — and what should we build next?
- **Status:** researched
- **Related topics:** none yet (first capture/reconstruction topic; adjacent to `specs/sculpt-pipeline.md` and `specs/conversion-pipeline.md`)

## TL;DR

Splats and USDZ are **different render paths**: a Gaussian splat cannot be rendered inside a QuickLook/AR USDZ, because USDZ is `UsdGeomMesh` + `UsdPreviewSurface` with no splat primitive. So for a mesh-shipping, RealityKit-first editor, GS is useful in exactly two ways — (1) as a **capture/reconstruction front-end** we convert to a textured mesh, and (2) optionally as a **separate preview representation**. Two findings dominate the decision: **geometry extraction from splats is mature but clean UV-mapped PBR texturing is not** (you get diffuse/vertex-color at best), and **Apple's `PhotogrammetrySession` already produces exactly our format** (textured PBR USDZ, on Mac, no CUDA). The highest value × verifiability next bet is therefore an **Apple Object Capture "photos → USDZ" importer**, with a MetalSplatter-based splat *viewport* second, and a full GS→mesh reconstruction pipeline (offline/CUDA) as a forward-looking third.

## Comparison set

| Tool / source | How it solves this | Cost / complexity | License | Applicability to us |
|---|---|---|---|---|
| **Apple `PhotogrammetrySession`** (RealityKit, WWDC21/24) | Photos → textured mesh; detail `.preview`→`.raw` (`.raw` emits diffuse/normal/AO/roughness); outputs OBJ **and USDZ** | Native, on Apple-silicon macOS 12+, no CUDA/third-party | Apple SDK | **Build first** — outputs our exact mesh+`UsdPreviewSurface` format; slots into `AssetImporter` |
| **gaustudio** (arXiv 2403.19632) | Splat→mesh toolkit: render depth from trained gaussians → **VDBFusion TSDF → marching cubes → Open3D clean**; DPSR/Poisson alt; `texture_mesh.py` bakes **vertex color** only | CUDA-only rasterizer submodule; PyTorch; NVIDIA ≥6GB | **MIT except the rasterizer** (Inria non-commercial) — IP hazard | Recipe only; **offline/cloud**, not embeddable on Mac; no PBR out |
| **2DGS** (SIGGRAPH24, arXiv 2403.17888) | Surfels + TSDF fusion; ~0.80mm DTU Chamfer; reference object meshing | CUDA training | Open (Inria-derived rasterizer caveat) | Geometry extractor of choice (bounded objects) |
| **GOF / PGSR** (arXiv 2404.10772 / 2406.06521) | Opacity level-sets (unbounded) / planar-regularized; PGSR ~0.47mm = geometry leader | CUDA training | Open (rasterizer caveat) | Best geometry; unbounded scenes |
| **SuGaR** (CVPR24, arXiv 2311.12775) | Poisson-bind gaussians to mesh; **uniquely exports UV-textured `.obj`** (diffuse via Nvdiffrast) | CUDA | Open | Only mature path to a *UV* texture — diffuse only |
| **GS-IR / Ref-Gaussian** (arXiv 2311.16473 / 2412.19282) | Inverse rendering: recover albedo/roughness/**metallic** + env (split-sum, glTF-compatible model) | CUDA, heavy; albedo–light entanglement | Open | Values map to `UsdPreviewSurface`; output is per-gaussian, needs mesh+UV+bake bridge |
| **`scier/MetalSplatter`** | Swift/Metal splat renderer; reads PLY/SPZ/.splat; iOS/macOS/visionOS incl. VP stereo | Docs incomplete; sibling `MTKView` | **MIT** | **Reuse** for an in-app splat viewport + its `PLYIO`/`SplatIO` parsers |
| **Niantic `.spz`** (`nianticlabs/spz`) + `scier/spz-swift` | Quantized splat transport, ~10× smaller than PLY; Swift port exists | Simple parse | **MIT** | I/O format of choice for splats; Swift port drops in |
| **OpenUSD `UsdVolParticleField3DGaussianSplat`** (v26.03) `[VERIFY]` | Native USD splat schema + `hdParticleField` ref renderer + PLY→USD script | Depends on usd-core wheel exposing it | Apache-2.0 | Native in-project splat representation *if* our wheel has it |
| **RealityKit `GaussianSplatComponent`** (WWDC26 / visionOS 27) `[VERIFY]` | Native splat render from position/scale/rotation/opacity/SH buffers; format-agnostic | macOS availability unconfirmed | Apple SDK | Would let splats render *inside* the RealityKit viewport — resolves the sibling-view question |
| **Open3D / PoissonRecon / VDBFusion** | Screened-Poisson / TSDF surface reconstruction, CPU | CPU, buildable on Apple silicon | MIT / MIT / MIT (OpenVDB Apache-2.0) | **CUDA-free** meshing usable from bundled Python |

> Every external claim is cited inline in Sources. Items tagged `[VERIFY]` are mid-2026 releases the SOTA thread could not cross-check against multiple independent primary sources with the same rigor as the 2023–2025 literature; confirm against Apple/Khronos/AOUSD primaries and the actual bundled `usd-core` wheel before committing code to them.

## State of the art

**Core pipeline (mature).** COLMAP SfM → `gsplat` (nerfstudio's production library, arXiv 2409.06765; ~4× less memory than Inria reference, bundles absgrad + Mip-Splatting AA + 3DGS-MCMC densification) → 2DGS/GOF/PGSR for meshing. Mip-Splatting (arXiv 2311.16493) is the standard anti-aliasing; 3DGS-MCMC (NeurIPS24) is the robustness-to-bad-init densifier.

**Mesh extraction (geometry mature, PBR texturing NOT).** DTU mean Chamfer (mm, lower better): PGSR ~0.47 (leader), RaDe-GS ~0.68, GOF ~0.74, 2DGS ~0.80. All produce **geometry + per-vertex color only — no UVs, no texture, no PBR**. SuGaR alone bakes a **diffuse** UV texture. 2025 PBR-baking work (TexGaussian CVPR25, GS-2M) is bleeding-edge, often *generative* (texture an input mesh) rather than reconstructive, and mostly without released, reproducible code. **A watertight, UV-mapped, true-PBR mesh from a real capture with mature open code does not exist today.** The realistic chain is: GS geometry (2DGS/GOF/PGSR) → retopo → UV unwrap → bake diffuse (+ optional delight) → USDZ. gaustudio implements exactly the geometry half of this (VDBFusion TSDF + marching cubes, or DPSR Poisson), plus vertex-color/`mvs-texturing` color, and nothing on the PBR side.

**Material decomposition (recovers non-baked appearance, stays splats).** GS-IR / Ref-Gaussian / IRGS recover albedo/roughness/metallic + environment using the same metallic-roughness split-sum model `UsdPreviewSurface` expects — so recovered *values* are conceptually portable. Failure modes: albedo–lighting ambiguity (shadows bake into base color), noisy normals, metallic being the weakest channel. Output is per-gaussian, not a UV set.

**Apple ecosystem (decisive).** QuickLook/USDZ do **not** render splats (USDZ spec + Apple forum 804604) — you can embed the bytes, iOS AR QuickLook won't draw them. On-device, `scier/MetalSplatter` (MIT) is the reference cross-platform renderer and its parsers are reusable. Crucially, **`PhotogrammetrySession`** is a fully-supported native "photos → textured PBR USDZ" path: full reconstruction on Apple-silicon macOS, detail levels up to `.raw` (diffuse/normal/AO/roughness maps), no splat plumbing, no CUDA. Newly (mid-2026, `[VERIFY]`): RealityKit `GaussianSplatResource`/`GaussianSplatComponent` (buffer-fed, format-agnostic) in visionOS 27; before 27 there was no native support.

**Standards/interop.** Raw layer is fragmented (INRIA `.ply` de-facto). Compressed delivery is converging on **`.spz`** (Niantic, MIT, multi-engine) and PlayCanvas **SOGS**. Emerging (`[VERIFY]`): glTF `KHR_gaussian_splatting` (+ SPZ compression companion) so splats coexist with meshes in one file, and OpenUSD `UsdVolParticleField` schema. `playcanvas/supersplat` (MIT) is the widest-importer open editor; `SplatTransform` is the conversion glue.

## Recommended approach for OpenUSDZEditor

Sequenced by (value to target users) × (verifiability today):

1. **Apple Object Capture importer — "Photos → USDZ" (build next).** A new `ConversionKit` importer/pipeline wrapping `PhotogrammetrySession`. It is native, CUDA-free, produces exactly mesh + `UsdPreviewSurface`, and re-uses the existing `AssetImporter`/`ConversionStage` protocol, batch engine, and `ComplianceChecker`/`ExportGate`. Architecturally it mirrors the `SculptKit` staged, quality-gated philosophy (deterministic mechanical work; explicit acceptance gates) — the pure planning/validation logic lives in a testable module, the `PhotogrammetrySession` call is an injected process seam (like `usdrecord`). This is the strongest, lowest-risk differentiator: no competitor open USDZ editor turns a folder of photos into a validated, editable USDZ in-app.

2. **Splat viewport + I/O (`SplatKit`, second).** A new pure-ish leaf module for splat parsing (PLY/`.spz` via a clean-room reader informed by `spz-swift`'s MIT layout) + a `ViewportKit` sibling `MTKView` renderer (clean-room, MetalSplatter-informed) to *preview* captures as splats. This is a **viewer** feature, explicitly not a USDZ payload. Gate the renderer choice on the `[VERIFY]` macOS availability of RealityKit `GaussianSplatComponent`: if it ships on macOS, render splats inside the existing RealityKit viewport and skip the separate Metal view.

3. **GS→mesh reconstruction (forward-looking third).** An importer that ingests a splat capture (`.ply`/`.spz`) and reconstructs a mesh via CUDA-free CPU Poisson/TSDF (Open3D/PoissonRecon/VDBFusion in bundled Python) for splats already reduced to oriented points/depth, **or** treats a full 2DGS/GOF/PGSR/gaustudio run as an **offline/cloud preprocessing stage** and imports the resulting mesh. Own the retopo→UV→diffuse-bake→USDZ tail ourselves; be honest that PBR beyond diffuse is not yet a solved import.

### Rejected alternatives

- **Splats as a USDZ payload / QuickLook splat export** — QuickLook and the USDZ AR profile don't render splats; shipping them in our exported `.usdz` would produce files that don't display for the primary audience. Never round-trip splats through export.
- **Embedding gaustudio / a GS trainer in-process on Mac** — the diff-gaussian-rasterizer is CUDA-only (no Metal/MPS port) *and* carries Inria's non-commercial license. Cannot run on Apple silicon, cannot ship commercially. Recipe only; keep any real training/extraction offline.
- **Reconstruction-time PBR material recovery (GS-IR class) as v1** — bleeding-edge, CUDA-heavy, per-gaussian (not UV), and albedo-contaminated. Out of scope until a reproducible mesh+UV+PBR-bake exists; revisit as research.
- **A general splat editing DCC (SuperSplat-style)** — out of scope per PRD; we author USD with focused tools, not a splat-manipulation suite.

## RealityKit / constraint reconciliation

- **Renderer = compatibility test.** Everything shippable stays mesh + `UsdPreviewSurface`; `PhotogrammetrySession` output is already exactly this, so path 1 degrades trivially and passes `arkit`/`arkit-strict` after the normal validation pass. Splats (path 2) are preview-only and never enter the export/`ExportGate` path.
- **Module layering.** `SplatKit` must be a leaf (like `MeshKit`/`QuickLookKit`): pure splat data model + parse/validate logic, no UI/GPU/Python; `ViewportKit` consumes it for the Metal/RealityKit render, `EditorUI` hosts the sibling view. The `PhotogrammetrySession` and any Python reconstruction call are process/framework seams injected behind protocols and coverage-excluded with annotations, exactly as `usdrecord` and the Python bridge already are.
- **`USDCore`/`MeshKit` stay pure Swift** — reconstruction math that is invariant-checkable (Poisson normals, TSDF grid, decimation, UV metrics) belongs in a pure module; the heavy solve behind a Python/CPU seam.
- **Gaps flagged loudly:** (a) macOS availability of native RealityKit splats `[VERIFY]`; (b) whether the bundled `usd-core` wheel exposes `UsdVolParticleField3DGaussianSplat` + `hdParticleField` (else UsdGeomPoints fallback); (c) no mature reconstructive PBR — diffuse-only honesty in the UI; (d) `PhotogrammetrySession` needs well-captured input, so a capture-guidance/quality gate is part of the feature, not an afterthought.

## License & provenance notes

- **gaustudio** — MIT **except** its `diff-gaussian-rasterization` submodule (Inria/MPII **non-commercial research** license). We borrow the *recipe* (depth→TSDF→marching-cubes; DPSR Poisson) only; **no CUDA rasterizer code, no reading GPL/non-commercial source into our implementation.**
- **MetalSplatter** (MIT), **spz-swift** (MIT), **Niantic spz** (MIT), **SuperSplat** (MIT) — permissive; we still implement parsers/renderers **clean-room** from the format layout + docs, recording that we used them as reference, not as copied code.
- **Open3D** (MIT), **PoissonRecon** (MIT; PLY sublib BSD), **VDBFusion** (MIT; OpenVDB now Apache-2.0), **PyTorch3D** (BSD) — all permissive and CUDA-free; safe to invoke from bundled Python.
- **Most GS meshing repos (2DGS/GOF/PGSR/SuGaR)** depend on the Inria rasterizer lineage — another reason they belong offline, not in-tree.

## Open questions

- **`[VERIFY]` macOS availability + minimum-OS of `GaussianSplatResource`/`GaussianSplatComponent`** — decides whether splat preview uses RealityKit or a sibling `MTKView`. Highest-leverage question. Check SDK headers / availability annotations, not blog posts.
- **`[VERIFY]`** Does our bundled `usd-core` wheel expose `UsdVolParticleField3DGaussianSplat` + `hdParticleField` (≥26.03), or do we need the UsdGeomPoints fallback / a schema plugin?
- **`[VERIFY]`** glTF `KHR_gaussian_splatting` ratification status and final attribute layout; confirm the SPZ compression companion extension name.
- Is a splat *preview* feature worth a new module before path 1 (photogrammetry) proves user demand? (Human/product call.)
- Cloud/offline story for GS→mesh: do we ship a documented external recipe, or a hosted helper? Non-commercial rasterizer license constrains any bundled option.
- PoissonRecon confirmed clang/arm64 build (pure C++, very likely, not documented).

## Sources

- GauStudio — https://github.com/GAP-LAB-CUHK-SZ/gaustudio ; arXiv:2403.19632 https://arxiv.org/abs/2403.19632 (accessed 2026-07-21)
- 3DGS (Kerbl 2023) https://arxiv.org/abs/2308.04079 ; Mip-Splatting https://arxiv.org/abs/2311.16493 ; gsplat https://arxiv.org/abs/2409.06765 ; 3DGS-MCMC (NeurIPS24)
- 2DGS https://arxiv.org/abs/2403.17888 ; GOF https://arxiv.org/abs/2404.10772 ; PGSR https://arxiv.org/abs/2406.06521 ; RaDe-GS https://arxiv.org/abs/2406.01467 ; SuGaR https://arxiv.org/abs/2311.12775
- GS-IR https://arxiv.org/abs/2311.16473 ; GaussianShader https://arxiv.org/abs/2311.17977 ; Ref-Gaussian https://arxiv.org/abs/2412.19282 ; IRGS https://arxiv.org/abs/2412.15867 ; TexGaussian https://arxiv.org/abs/2411.19654
- Apple PhotogrammetrySession — https://developer.apple.com/documentation/realitykit/photogrammetrysession ; WWDC21 https://developer.apple.com/videos/play/wwdc2021/10076/ ; Object Capture area mode WWDC24 https://developer.apple.com/videos/play/wwdc2024/10107/
- RealityKit native splats `[VERIFY]` — WWDC26 session 279 https://developer.apple.com/videos/play/wwdc2026/279/ ; https://developer.apple.com/documentation/visionos/gaussian-splats-on-visionos
- OpenUSD splat schema `[VERIFY]` — https://aousd.org/blog/openusd-v26-03/ ; https://www.cgchannel.com/2026/03/openusd-26-03-adds-support-for-3d-gaussian-splats/ ; UsdGeomPointInstancer https://openusd.org/dev/api/class_usd_geom_point_instancer.html ; houdini-gsplat https://github.com/plattipus/houdini-gsplat
- glTF splat extension `[VERIFY]` — https://www.khronos.org/blog/khronos-ogc-and-geospatial-leaders-add-3d-gaussian-splats-to-the-gltf-asset-standard ; PR https://github.com/KhronosGroup/glTF/pull/2490
- Formats — Niantic spz https://github.com/nianticlabs/spz ; spz-swift https://github.com/scier/spz-swift ; MetalSplatter https://github.com/scier/MetalSplatter ; SuperSplat https://github.com/playcanvas/supersplat ; SOG/Self-Organizing Gaussians https://arxiv.org/abs/2312.13299
- Reconstruction libs — PoissonRecon https://github.com/mkazhdan/PoissonRecon ; Open3D surface reconstruction https://www.open3d.org/docs/latest/tutorial/Advanced/surface_reconstruction.html ; VDBFusion https://github.com/PRBonn/vdbfusion ; OpenVDB license https://www.openvdb.org/license/
- USDZ has no splat primitive — https://openusd.org/release/spec_usdz.html ; Apple forum 804604
