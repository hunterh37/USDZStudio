# ConversionKit Specification — Universal → USDZ Pipeline

## Principles

1. **Transparent:** every conversion is a sequence of named stages with logged inputs/outputs. No black box — the log shows exactly what happened to the asset.
2. **Extensible:** importers and stages are protocol-conforming plugins; adding a format touches only ConversionKit.
3. **Deterministic:** same input + same preset → byte-stable output (required for batch pipelines and CI).

## Supported Inputs (v1)

| Format | Path | Notes |
|---|---|---|
| GLB / glTF 2.0 | Native Swift parser (`GLTFImporter`) | Primary path; full PBR metallic-roughness, KHR_materials_* subset, Draco via bundled decoder, skinning + animations |
| OBJ (+MTL) | ModelIO | Materials mapped MTL→PreviewSurface |
| STL, PLY | ModelIO | Geometry only; auto default material |
| DAE (Collada) | ModelIO/SceneKit | Best-effort |
| FBX | FBX2glTF helper → GLB path | Binary not bundled (license); one-click download flow, checksum-verified |
| USD/USDA/USDC | USDBridge | "Conversion" = repackage to usdz |

## Pipeline Model

```swift
struct ConversionContext {
    var sourceURL: URL
    var scene: IntermediateScene      // format-agnostic scene graph (ConversionKit's IR)
    var options: ConversionPreset
    var diagnostics: [Diagnostic]
    var artifacts: [URL]              // temp textures, etc.
}
```

`IntermediateScene` is the internal representation (nodes, meshes, PBR materials, skins, animations) that importers produce and the `USDZWriter` consumes. This decouples N input formats from the single high-quality USD writer.

### Standard stage sequence (glTF preset)

1. `parse` — importer → IntermediateScene
2. `decode-compressed` — Draco/meshopt geometry decode + KTX2/Basis image transcode (→ RGBA8 → PNG). Because the compressed bytes are intrinsic to glTF parsing (a Draco primitive carries no plain accessors; a meshopt buffer view is not readable until expanded), decode is performed *inside* the native `GLTFImporter` through injected codec seams (`GeometryDecompressor`, `BufferViewDecompressor`, `TextureTranscoder`) rather than as a separate post-parse `ConversionStage`. The seams keep the orchestration 100%-unit-testable against fakes; the real native codec bindings (libdraco, meshoptimizer, libktx/Basis) are the single coverage-excluded surface, exactly like the capture/`usdrecord` seams. Decode is keyed off `extensionsUsed`/`extensionsRequired`: a *required* extension we cannot honor fails loudly (`requiredExtensionUnsupported`), and every decode/failure emits a diagnostic — never a silent drop. Re-compression on *export* (KTX2/meshopt out) is a separate advanced-profile concern (Phase 7).
3. `sanitize-names` — USD-legal prim names, dedupe, preserve original in metadata
4. `weld-and-index` — optional vertex welding, triangulation of non-tri prims
5. `materials` — glTF PBR → UsdPreviewSurface mapping (see table below)
6. `textures` — resize to max (default 2048), format policy (normal maps stay PNG; albedo JPEG at q0.90 optional), ORM split/pack per target
7. `units-and-axes` — scale to metersPerUnit=1, Y-up enforcement, optional ground-align + center
8. `usd-author` — IntermediateScene → USD stage via bridge
9. `package` — usdz packaging (mind 64-byte alignment via UsdUtils)
10. `validate` — ValidationKit pass; warnings attached to result
11. `thumbnail` — offscreen RealityKit render → embedded + sidecar PNG

Each stage is skippable/configurable per preset. Presets ship as JSON (`ecommerce`, `quicklook-strict`, `visionos`, `lossless`) and users can save their own.

### Material mapping (glTF → UsdPreviewSurface)

| glTF | UsdPreviewSurface |
|---|---|
| baseColorFactor/Texture | diffuseColor (texture via UsdUVTexture + st reader) |
| metallic/roughnessFactor+Texture | metallic (B channel), roughness (G channel) |
| normalTexture | normal (scale honored) |
| occlusionTexture | occlusion (R channel) |
| emissiveFactor/Texture (+KHR_emissive_strength) | emissiveColor |
| alphaMode BLEND/MASK | opacity / opacityThreshold |
| KHR_materials_clearcoat | clearcoat, clearcoatRoughness |
| KHR_materials_ior | ior |
| KHR_materials_transmission | opacity approximation + warning diagnostic |
| doubleSided | doubleSided |

Unsupported extensions produce **warnings, never silent drops**.

## Batch Engine

- `BatchJob`: input folder/glob → preset → output folder. Concurrency-limited task group (default = performance cores).
- Emits `report.csv` + `report.json`: per-file status, warnings, tri counts, texture memory, output size.
- Resumable: completed outputs skipped by content hash unless `--force`.
- Fully usable from CLI target: `openusdz convert-batch ./in ./out --preset ecommerce`.

## UI

- **Single convert:** drop non-USD file on app → Conversion sheet: preset picker, stage checklist with disclosure options, live log pane, Convert & Open.
- **Batch window:** table of queued files, per-row status/warnings, aggregate progress, "Open report".

## Testing

- CI runs the Khronos glTF-Sample-Models corpus; asserts conversion success rate and validates every output with ComplianceChecker.
- Golden-image tests: offscreen render of converted asset vs. reference render, perceptual diff threshold.
