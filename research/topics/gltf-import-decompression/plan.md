# Implementation Plan — glTF Import Decompression (Draco + KTX2/Basis + meshopt)

- **Slug:** `gltf-import-decompression` (pairs with `research.md`)
- **Date:** 2026-07-22
- **Source research:** `./research.md`
- **Roadmap slot:** Phase 2 — closes the two open `[ ]` Phase 2 items (native GLB "Draco decode still TODO"; the glTF sample-model corpus gate, which is currently blocked because compressed samples fail). Unblocks the e-commerce target user and the Milestone 2 public launch's converter credibility. Depends on nothing already-unbuilt.
- **Status:** proposed

## Summary

Add the `decode-compressed` stage that `specs/conversion-pipeline.md` already names to `ConversionKit`, so the native glTF importer decodes `KHR_draco_mesh_compression`, `KHR_texture_basisu`, and `EXT_meshopt_compression` into the plain `IntermediateScene` the `USDZWriter` consumes. Draco/meshopt expand to plain accessors; KTX2/Basis transcodes to RGBA8 then re-encodes to PNG/JPEG through the existing `textures` stage — so every output stays `arkit`-clean. Unsupported *required* extensions fail loudly with a specific diagnostic; nothing is dropped silently.

## Module targets

| Module (`Packages/*`) | Change | New dependency edges | Legal per architecture.md? |
|---|---|---|---|
| ConversionKit | New `DecodeCompressedStage: ConversionStage`; `GeometryDecompressor`/`TextureTranscoder` protocol seams; wire into the glTF preset sequence between `parse` and `sanitize-names` | External C/C++ codec targets (libdraco, libktx/basis, meshoptimizer) via fetched binary or SwiftPM C target — **no new internal edge** (ConversionKit already `→ USDCore`) | yes — ConversionKit owns all importers/stages (architecture.md); adding a format/stage "touches only ConversionKit" |
| ValidationKit | (no change) existing PNG/JPEG-only texture rule already catches any KTX2 that escapes decode | — | yes |
| scripts/ | `fetch-*.sh` for the codec binaries, mirroring `fetch-python-runtime.sh` / `fetch-fbx2gltf.sh`; network allowlist already permits the source hosts | — | n/a |

> Confirm: no `USDCore`/`MeshKit` change, so their pure-Swift purity is untouched. The codec binding is the only non-pure surface and it lives behind a ConversionKit protocol seam, coverage-excluded with a manifest reason exactly like `PhotogrammetrySessionRunner`.

## Data model / API

```swift
// Seams — the pure orchestration is tested against fakes; the real codec binding is the one excluded line.
public protocol GeometryDecompressor: Sendable {
    /// Draco/meshopt → plain attribute + index buffers for one primitive.
    func decode(_ primitive: CompressedPrimitive) throws -> DecodedGeometry
}
public protocol TextureTranscoder: Sendable {
    /// KTX2/Basis → uncompressed RGBA8 + carried color space.
    func transcode(_ ktx2: Data, usage: TextureColorSpace) throws -> DecodedImage
}

public struct DecodeCompressedStage: ConversionStage {
    let geometry: GeometryDecompressor
    let texture: TextureTranscoder
    public func run(_ ctx: inout ConversionContext) throws // expands ctx.scene in place, appends diagnostics
}

enum ConversionError {
    case unsupportedRequiredExtension(name: String)   // extensionsRequired lists something we can't decode
    case decodeFailed(extension: String, detail: String)
}
```

Decode is keyed off the parsed glTF `extensionsUsed`/`extensionsRequired`. `DecodedImage` carries `TextureColorSpace` (sRGB for base-color/emissive, linear for normal/ORM) so the downstream `textures` stage and the OKLab recolor path stay correct.

## Algorithm

1. **Detect.** Read `extensionsRequired`. For any entry not in the decodable set `{KHR_draco_mesh_compression, KHR_texture_basisu, EXT_meshopt_compression}` (plus already-handled `KHR_materials_*`), throw `unsupportedRequiredExtension`. Extensions only in `extensionsUsed` but absent from data are no-ops.
2. **meshopt first** (it wraps raw bufferViews): for each `bufferView.extensions.EXT_meshopt_compression`, decode `(mode, filter, byteStride, count)` → plain bytes; replace the view. Compose before Draco/accessor interpretation.
3. **Draco:** for each primitive with `KHR_draco_mesh_compression`, decode the referenced bufferView → POSITION/NORMAL/TEXCOORD_n/TANGENT/JOINTS_n/WEIGHTS_n + indices; dequantize to float32 (USD `points`/`normals` are 32-bit float). Decoded data overrides the primitive's hint accessors per spec. Preserve duplicate/degenerate indices unchanged so `weld-and-index` stays deterministic.
4. **KTX2/Basis:** for each texture with `KHR_texture_basisu`, transcode source → RGBA8, tag color space, substitute as the texture's image source. The existing `textures` stage then resizes + re-encodes to the profile's PNG/JPEG policy and does ORM split/pack unchanged.
5. **Diagnostics:** every decode emits an info diagnostic (extension, primitive/texture, before/after byte size); every failure a specific error. No silent path.

Edge cases: an asset using *both* Draco and meshopt (decode meshopt bytes, then Draco); Draco primitive missing tangents with a normal map present → defer to the existing tangent handling (flag if absent); KTX2 UASTC vs ETC1S both transcode to RGBA8 identically for our purposes; non-float quantized Draco attributes → dequantize.

## RealityKit export-profile behavior

- **`arkit` / `arkit-strict`:** output is plain geometry + PNG/JPEG textures — already the profile floor, so decoded assets pass ComplianceChecker with no new construct to flag. KTX2 that failed to transcode would be caught by the existing PNG/JPEG-only texture rule (defense in depth), not shipped.
- **`lossless`/full-USD:** identical import behavior — we always decode on import; re-compression (KTX2/meshopt on *export*) is Phase 7 and out of this plan.
- Nothing about this feature can *worsen* a profile verdict: it only turns previously-unloadable assets into RealityKit-clean ones.

## Harness (lands in the SAME PR)

- **Invariants:** decode is deterministic (same input → byte-stable expanded buffers, per the ConversionKit determinism principle); a Draco-decoded primitive's vertex/index counts match the pre-compression counts recorded in the fixture; decoded + re-encoded texture round-trips through the existing PNG/JPEG stage stably.
- **Golden files:** committed compressed fixtures with their expected decoded topology/attribute snapshots — a Draco cube, a KTX2-textured quad (ETC1S and UASTC), a meshopt-encoded mesh, and one asset combining Draco+meshopt. Assert decoded geometry matches an uncompressed twin of the same asset within float tolerance.
- **Corpus gate:** this is the item that lets the **Phase 2 / T1 glTF sample-model corpus gate** actually go green — the Khronos sample set includes Draco/KTX2 variants that fail today. Wire the corpus gate in the same PR (re-open-and-validate each output through ComplianceChecker, per spec §3).
- **Coverage:** ConversionKit holds its **100% logic floor** — orchestration fully covered against fake `GeometryDecompressor`/`TextureTranscoder`; the real native-codec binding is the single coverage-excluded seam with a reviewed manifest reason.
- **CLI matrix:** `openusdz convert` over {plain, draco, ktx2, meshopt, draco+meshopt, unsupported-required-ext} × {default, --json}; the unsupported case asserts a non-zero exit and a specific diagnostic.

## Rollout

1. Land the `GeometryDecompressor`/`TextureTranscoder` protocols + `DecodeCompressedStage` orchestration with fakes and full unit coverage (no real codec yet) — provable without binaries.
2. Add the codec `fetch-*.sh` + real binding behind the seams; annotate the excluded line.
3. Add golden compressed fixtures + decoded-twin assertions.
4. Turn on the glTF sample-model corpus gate (closes the second open Phase 2 item).
5. CLI matrix + diagnostics polish.

## Risks & open questions

- **Codec binding form (human decision):** fetched prebuilt Apple-Silicon binaries vs. SwiftPM C targets from source. Prefer fetched (build-time, matches usd-core/FBX2glTF precedent); confirm a reliable ASi build/host for libdraco + libktx.
- **libdraco native vs WASM:** web loaders use WASM; a native Mac build is the right call — confirm availability.
- **Tangent synthesis** for Draco assets lacking tangents but carrying normal maps — recommend deferring to existing pipeline; verify that stage synthesizes (MikkTSpace) rather than shipping wrong tangents.
- **KTX2 EXR/AVIF adjacency:** out of scope here (USDZ-spec-legal but not `arkit`); note for a later advanced-profile texture task.

## Acceptance criteria

- [ ] A Draco-compressed GLB from the Khronos sample set converts to a valid, RealityKit-clean USDZ with correct geometry.
- [ ] A `KHR_texture_basisu` asset converts with textures re-encoded to PNG/JPEG and correct color spaces (base-color sRGB, normal/ORM linear).
- [ ] An `EXT_meshopt_compression` asset (and a Draco+meshopt asset) converts correctly.
- [ ] An asset listing an undecodable extension in `extensionsRequired` fails with a specific diagnostic and non-zero CLI exit — never a silent drop.
- [ ] ConversionKit 100% logic floor held; the native codec binding is the only excluded seam, with a manifest reason.
- [ ] The glTF sample-model corpus gate is live and green in CI (closes the second open Phase 2 item).
