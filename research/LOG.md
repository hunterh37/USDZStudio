# Research Log — 3D tooling & rendering research → plans

Append-only registry of every research topic. Newest first. One row per topic;
refine a topic in place (don't spawn `-v2` — supersede with a note). Maintained by
the `research-3d` skill / `/research-3d` command. See `research/README.md`.

Status vocabulary: `researched` (findings written) · `planned` (plan.md ready to
build) · `building` (a PR is implementing it) · `landed` (shipped) · `superseded`.

| Date | Slug | Question (short) | Recommendation (one line) | Target module(s) | Roadmap slot | Status |
|---|---|---|---|---|---|---|
| _example_ | `wireframe-overlay` | How to render wireframe-on-shaded in a RealityKit viewport | Metal line-overlay pass keyed off the debug-mode material swap | ViewportKit | Milestone 2 (viewer surface) | _example row — delete_ |
| 2026-07-21 | `gaussian-splatting-to-usdz` | Where do Gaussian Splatting & real-world capture fit a mesh-shipping, RealityKit-first USDZ editor? | Build an Apple `PhotogrammetrySession` "photos → USDZ" importer first (native, CUDA-free, outputs our exact format); splat preview viewport second; GS→mesh reconstruction third. Splats are never a USDZ payload. | CaptureKit (new), ConversionKit, EditorUI, CLI; SplatKit (new)+ViewportKit for follow-on | New Phase 2.5 (Capture Import), extends Phase 2 | planned |
