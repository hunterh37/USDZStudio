# Research — glTF Import Decompression Completeness (Draco + KTX2/Basis + meshopt)

- **Slug:** `gltf-import-decompression`
- **Date:** 2026-07-22
- **Question:** A large fraction of real-world glTF/GLB deliverables (especially the e-commerce corpus our target users hand us) ship geometry Draco-compressed and textures in KTX2/Basis Universal, increasingly with `EXT_meshopt_compression`. Our native `GLTFImporter` decodes none of these, so it silently fails or drops data on exactly the assets that matter most. What is the SOTA decode path, and how do we build it inside ConversionKit while staying RealityKit/`arkit`-clean on the way out?
- **Status:** planned
- **Related topics:** `gaussian-splatting-to-usdz` (both extend Phase 2 conversion); `conversion-pipeline.md` §"decode-compressed" stage already declares this work.

## TL;DR

Draco (`KHR_draco_mesh_compression`), KTX2/Basis (`KHR_texture_basisu`), and meshopt (`EXT_meshopt_compression`) are now table-stakes for commerce-ready glTF — the Khronos Asset Creation Guidelines 2.0 (SIGGRAPH 2025) treat them as the default delivery encodings, and every mainstream web viewer (three.js, Babylon.js, `<model-viewer>`) decodes them. Our converter must **decode on import** or it fails on the majority of modern glTF. The clean architecture is a new `decode-compressed` pass in ConversionKit that expands compressed accessors/images into the plain `IntermediateScene` the `USDZWriter` already consumes. Critically, **decode is one-directional for the `arkit` profile**: USDZ/AR QuickLook accepts only PNG/JPEG textures, so KTX2 must transcode to PNG/JPEG on the way into USD — re-encoding to KTX2/meshopt is an advanced-profile *export* concern (Phase 7), not part of this import work.

## Comparison set

| Tool / source | How it solves this | Cost / complexity | License | Applicability to us |
|---|---|---|---|---|
| **three.js** `DRACOLoader` / `KTX2Loader` / `MeshoptDecoder` | Loaders pull in Google's `draco_decoder` (WASM/JS), Khronos `basis_transcoder`, and `meshoptimizer`'s decoder; expand accessors before scene build | Moderate — external decoders as WASM/native | Draco Apache-2.0, Basis Apache-2.0, meshoptimizer MIT | Confirms the standard is "bind the reference decoders, expand to plain buffers" — same shape we want ([three.js docs](https://threejs.org/docs/#examples/en/loaders/DRACOLoader)) |
| **Babylon.js** glTF loader | Same three decoders wired as extension handlers keyed off `extensionsUsed` | Moderate | Apache-2.0 | Validates keying decode off `extensionsUsed`/`extensionsRequired` |
| **glTF-Transform** (`KHRDracoMeshCompression`, `KHRTextureBasisu`, `EXTMeshoptCompression`) | Node library that reads/writes each extension around the reference codecs; canonical CPU-side decode/encode reference | Low to bind, clear API contract | MIT (lib), codecs Apache-2.0/MIT | Best documentation of the exact accessor/image transform each extension performs ([gltf-transform.dev](https://gltf-transform.dev/modules/extensions)) |
| **Khronos Asset Creation Guidelines 2.0** (Aug 2025) | Declares Draco + KTX2 + meshopt the commerce-ready delivery defaults | n/a (spec/guidance) | n/a | Establishes these as *expected*, not exotic — this is why it's table-stakes ([khronos.org blog](https://www.khronos.org/blog/introducing-asset-creation-guidelines-2.0-siggraph-2025)) |
| **Google Draco** | `libdraco` C++ (also a WASM build) decodes compressed mesh attributes back to plain vertex/index arrays | Native C++ build or WASM | Apache-2.0 | The decoder we bind; 60–90% vertex-data reduction is the reason artists ship it ([castercomm/Khronos announce](https://castercomm.com/client-newsroom/khronos-announces-gltf-geometry-compression-extension-using-google-draco-technology)) |
| **Binomial/Khronos Basis Universal** (`libktx` / `basis_transcoder`) | Transcodes KTX2/Basis supercompressed textures to a target GPU or plain format; for us the target is **RGBA8 → re-encode PNG/JPEG** | Native C++ build | Apache-2.0 | We transcode to uncompressed then hand to the existing `textures` stage ([khronos.org/ktx](https://www.khronos.org/ktx/)) |

> USDZ/AR QuickLook texture-format constraint verified: the USDZ spec permits PNG/JPEG/EXR/AVIF, but **Apple AR Quick Look and ARKit accept only PNG and JPEG** (HEIC on visionOS). ([openusd.org usdz spec](https://openusd.org/release/spec_usdz.html), corroborated by [3dcloud USDZ guide](https://3dcloud.com/usdz-files/)). This is the linchpin: KTX2 in → PNG/JPEG out.

## State of the art

The universally-adopted pattern is **decode-at-load into plain buffers**, keyed off the glTF `extensionsUsed`/`extensionsRequired` arrays:

- **`KHR_draco_mesh_compression`** — a mesh primitive's `extensions.KHR_draco_mesh_compression` points at a `bufferView` holding a Draco-encoded blob plus an attribute→Draco-id map. The decoder reconstructs POSITION/NORMAL/TEXCOORD/JOINTS/WEIGHTS accessors and the index buffer. Per glTF rules, when Draco is in `extensionsRequired` the primitive's top-level `attributes`/`indices` are hints; the decoded data wins. Edge cases: quantized attributes need dequantization to float32 (USD `points` are 32-bit float — no precision expansion needed beyond that); degenerate/duplicate indices must survive into our welding stage unchanged so `weld-and-index` stays deterministic.
- **`KHR_texture_basisu`** — a texture's `extensions.KHR_texture_basisu.source` indexes a KTX2 image (ETC1S or UASTC payload). We transcode to uncompressed RGBA8 (the guaranteed-available target), then the existing `textures` stage re-encodes to the profile's PNG/JPEG policy and does resize/ORM handling exactly as it does for a plain PNG source today. Color-space matters: base-color/emissive are sRGB, normal/ORM are linear — the KTX2 `DFD`/glTF texture usage tells us which, and this must be carried so re-encode and our OKLab recolor path stay correct.
- **`EXT_meshopt_compression`** — a `bufferView.extensions.EXT_meshopt_compression` describes a meshopt-encoded region (`mode` ATTRIBUTES/TRIANGLES/INDICES, `filter` NONE/OCTAHEDRAL/QUATERNION/EXPONENTIAL, byteStride, count). meshoptimizer's decoder expands it back to the plain `bufferView` bytes; decode is independent of and can compose with Draco (an asset may use both).

All three are **CPU-side, deterministic** transforms that expand compressed representations into exactly the plain accessors/images a naive glTF would have carried — which is why they slot in as a single pass *before* our existing material/texture/units stages without touching them.

## Recommended approach for OpenUSDZEditor

Build the `decode-compressed` stage that `specs/conversion-pipeline.md` already names (stage 2 of the glTF preset) as a real `ConversionStage`, living in **ConversionKit**, running after `parse` and before `sanitize-names`:

1. Detect required/used extensions from the parsed glTF. If an asset lists an extension in `extensionsRequired` that we cannot decode, **fail loudly with a specific diagnostic** (never silently drop) — matching the spec's "unsupported → warning/error, never silent drop" rule; an *unused* listed-but-absent extension is a no-op.
2. **Draco** → decode each compressed primitive to plain POSITION/NORMAL/TEXCOORD/tangent/skin accessors + indices in the `IntermediateScene` (or a pre-IR buffer expansion, whichever keeps the importer's boundary cleanest).
3. **meshopt** → expand encoded bufferViews to plain bytes before accessor interpretation (compose with Draco correctly).
4. **KTX2/Basis** → transcode to RGBA8, hand to the existing `textures` stage; carry the color-space tag.
5. Each decoder is a **process/library seam behind a protocol** (`GeometryDecompressor`, `TextureTranscoder`) so the pure-orchestration logic is 100%-coverable against fakes, and the native codec binding (the one uncoverable line) is isolated and annotated — exactly the pattern `ObjectCaptureImporter`/`PhotogrammetryRunning` established in Phase 2.5.

Bind the **reference C/C++ decoders** (libdraco, libktx/basis_transcoder, meshoptimizer) rather than reimplementing — these are the canonical, artist-matching codecs, all permissively licensed, and reimplementing Draco's entropy decode from scratch is both pointless and a correctness risk. Prefer a fetched-at-build binary/wheel (mirrors the usd-core and FBX2glTF precedent) over vendoring, keeping the repo lean.

### Rejected alternatives

- **Reimplement decoders in pure Swift.** Rejected — enormous surface area, correctness risk against artist assets, no upside. Idea-borrowing doesn't apply to a bit-exact codec; use the reference implementation.
- **Decode via bundled Python/usd-core.** usd-core has no Draco/KTX2 transcode; would add a heavy Python round-trip for a CPU transform that belongs in the deterministic Swift pipeline. Rejected.
- **Keep KTX2 through to USDZ export.** Rejected for the `arkit` profile — AR Quick Look won't render it. KTX2/Basis *export* is a legitimate advanced-profile feature but belongs to Phase 7 material/texture authoring, not import.
- **Route everything through FBX2glTF/gltf-transform CLI.** Adds an external Node/binary dependency for something we should own in-pipeline; acceptable as an interim decode shim but not the destination.

## RealityKit / constraint reconciliation

- **Renderer:** decode produces plain meshes + PNG/JPEG textures — exactly what RealityKit and AR Quick Look already consume. No RealityKit feature gap; this is purely making import *reach* the format RealityKit needs.
- **`arkit` profile floor:** the whole point of decoding on import is that the output is already RealityKit-clean. KTX2→PNG/JPEG transcode is mandatory for `arkit`; ComplianceChecker already flags non-PNG/JPEG textures, so a bug that let KTX2 slip through would be *caught* by the existing gate rather than shipped.
- **Module deps:** all work is inside ConversionKit (already `→ USDCore`), plus new external-codec seams. No new internal edge, no layering change. Pure-Swift purity of USDCore/MeshKit is untouched.
- **No-DCC rule:** this is format ingestion, not authoring surface — squarely in scope.

## License & provenance notes

- **libdraco** — Apache-2.0. **Basis Universal / libktx** — Apache-2.0. **meshoptimizer** — MIT. All permissive; safe to bind and redistribute with attribution. We use the reference codecs as libraries (not clean-room reimplementation), which is the intended use.
- three.js (MIT) and Babylon.js (Apache-2.0) consulted only for the *integration pattern* (keying off `extensionsUsed`, expand-to-plain); no code copied.
- glTF-Transform (MIT) consulted as the clearest spec-of-the-transform reference.

## Open questions

- **Binding form:** fetched prebuilt binaries (build-script, like usd-core) vs. SwiftPM C targets compiled from source. Prefer fetched to keep build times sane; a human should confirm the fetch-host policy (network allowlist currently permits github/pypi/npm — codec sources are reachable).
- **Draco decoder availability:** native `libdraco` build vs. the Draco WASM used by web loaders. Native is the right call for a Mac app; confirm an Apple-Silicon build path.
- **Tangents:** if a Draco asset omits tangents and a normal map is present, do we synthesize (MikkTSpace) here or defer to the existing pipeline? Recommend deferring to the existing normal/tangent handling; flag if that stage doesn't synthesize.

## Sources

- OpenUSD USDZ File Format Specification — https://openusd.org/release/spec_usdz.html (accessed 2026-07-22)
- Khronos, Asset Creation Guidelines 2.0 (SIGGRAPH 2025) — https://www.khronos.org/blog/introducing-asset-creation-guidelines-2.0-siggraph-2025 (accessed 2026-07-22)
- Khronos KTX / Basis Universal — https://www.khronos.org/ktx/ (accessed 2026-07-22)
- glTF-Transform extension docs (Draco/Basisu/meshopt) — https://gltf-transform.dev/modules/extensions (accessed 2026-07-22)
- Khronos announces glTF Draco geometry compression — https://castercomm.com/client-newsroom/khronos-announces-gltf-geometry-compression-extension-using-google-draco-technology (accessed 2026-07-22)
- three.js DRACOLoader / KTX2Loader docs — https://threejs.org/docs/ (accessed 2026-07-22)
- 3D Cloud, USDZ file format guide (Apple PNG/JPEG constraint) — https://3dcloud.com/usdz-files/ (accessed 2026-07-22)
