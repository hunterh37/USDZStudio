# Research Log — 3D tooling & rendering research → plans

Append-only registry of every research topic. Newest first. One row per topic;
refine a topic in place (don't spawn `-v2` — supersede with a note). Maintained by
the `research-3d` skill / `/research-3d` command. See `research/README.md`.

Status vocabulary: `researched` (findings written) · `planned` (plan.md ready to
build) · `building` (a PR is implementing it) · `landed` (shipped) · `superseded`.

| Date | Slug | Question (short) | Recommendation (one line) | Target module(s) | Roadmap slot | Status |
|---|---|---|---|---|---|---|
| 2026-07-22 | `gltf-import-decompression` | Decode Draco + KTX2/Basis + meshopt on glTF import (table-stakes converter gap, issue #127→#125) | Decode inside `GLTFImporter` via injected codec seams (geometry/bufferView/texture); 100%-covered routing + gating + diagnostics against fakes; native codec bindings are the single excluded seam | ConversionKit | Phase 2 (closes GLB "Draco TODO" + unblocks corpus gate) | building (orchestration + tests landed; native bindings + golden fixtures next) |
| 2026-07-21 | `lattice-deformer` | How to build a lattice/FFD cage deformer (control-point box gizmo) RealityKit-compatibly | Pure-Swift trivariate FFD in MeshKit, cage gizmo via the shared gizmo seam, bake deformed `points` on commit (no USD lattice schema) | MeshKit, EditingKit, ViewportKit, EditorUI | Phase 8 (mesh modeling), extends mesh-editing §Live vertex edit | building (PR #108) |
| _example_ | `wireframe-overlay` | How to render wireframe-on-shaded in a RealityKit viewport | Metal line-overlay pass keyed off the debug-mode material swap | ViewportKit | Milestone 2 (viewer surface) | _example row — delete_ |
| 2026-07-21 | `gaussian-splatting-to-usdz` | Where do Gaussian Splatting & real-world capture fit a mesh-shipping, RealityKit-first USDZ editor? | Build an Apple `PhotogrammetrySession` "photos → USDZ" importer first (native, CUDA-free, outputs our exact format); splat preview viewport second; GS→mesh reconstruction third. Splats are never a USDZ payload. | CaptureKit (new), ConversionKit, EditorUI, CLI; SplatKit (new)+ViewportKit for follow-on | New Phase 2.5 (Capture Import), extends Phase 2 | planned |
