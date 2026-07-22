# Implementation Plan — Real-World Capture → USDZ (Object Capture importer), with splat viewport + GS→mesh follow-ons

- **Slug:** `gaussian-splatting-to-usdz` (pairs with `research.md` in this folder)
- **Date:** 2026-07-21
- **Source research:** `./research.md`
- **Roadmap slot:** new **Phase 2.5 — Capture Import** (extends Phase 2 Conversion); splat viewport rides **Phase 1 viewer surface**; GS→mesh is a post-1.0 forward-looking importer. See "Roadmap placement" below.
- **Status:** proposed

## Summary

Turn a folder of photos into a validated, editable USDZ **inside the app**, by wrapping Apple's native `PhotogrammetrySession` as a first-class `ConversionKit` importer with a staged, quality-gated pipeline in the `SculptKit` idiom (deterministic mechanical work + explicit acceptance gates; the session call is an injected process seam). This is the headline build: native, CUDA-free, and it emits exactly our mesh + `UsdPreviewSurface` format, so it degrades trivially under `arkit` export. Two sequenced follow-ons: (2) a **splat preview viewport** (`SplatKit` leaf + `ViewportKit` renderer) that shows a capture as splats without ever putting them in the exported USDZ; (3) a **GS→mesh importer** that ingests `.ply`/`.spz` splat captures and reconstructs a mesh via CUDA-free CPU Poisson/TSDF (or imports the output of an offline 2DGS/GOF/gaustudio run).

## Module targets

| Module (`Packages/*`) | Change | New dependency edges | Legal per architecture.md? |
|---|---|---|---|
| **`CaptureKit`** (new leaf, pure Swift) | Pure capture-pipeline logic: `CaptureRequest`/`CaptureQuality` model, input-image validation, detail-level→profile mapping, acceptance gates, `BuildStep`-style plan. Authors no stage; runs no session. | → `USDCore`, `MeshKit` only | New package → needs `dependency-lint.sh` entry + `architecture.md` update + `testing.md` floor row (governance ritual, same PR) |
| **`ConversionKit`** | New `ObjectCaptureImporter: AssetImporter` + `ConversionStage`s that drive `CaptureKit`'s plan and invoke `PhotogrammetrySession` behind an injected `PhotogrammetryRunning` protocol seam | → `CaptureKit` (new), existing → `USDCore` | Yes — ConversionKit already owns importers; new edge to a leaf is legal |
| **`EditorUI`** | Capture import sheet (drop images → detail level → live progress → validate → open); reuses batch + `ExportGate` surfaces | existing → ConversionKit | Yes |
| **`CLI`** | `openusdz capture <images-dir> <out.usdz> --detail medium` subcommand (same pipeline headless) | existing → kits | Yes |
| **`SplatKit`** (new leaf, follow-on 2) | Pure splat data model + PLY/`.spz` parse/validate (clean-room). No UI/GPU/Python. | → none internal | New package → governance ritual |
| **`ViewportKit`** (follow-on 2) | Splat renderer: RealityKit `GaussianSplatComponent` if macOS-available `[VERIFY]`, else sibling `MTKView` (clean-room, MetalSplatter-informed) | → `SplatKit` (new) | Yes — ViewportKit may consume leaf modules |

> `CaptureKit`/`SplatKit` stay pure Swift leaves exactly like `MeshKit`/`QuickLookKit`. The `PhotogrammetrySession` call, any Python reconstruction, and Metal submission are process/framework seams injected behind protocols and coverage-excluded with annotations (same discipline as the `usdrecord` and Python-bridge seams).

## Data model / API

```swift
// CaptureKit — pure, Sendable, 100%-covered logic
public enum CaptureDetail: String, Sendable, Codable { case preview, reduced, medium, full, raw }

public struct CaptureRequest: Sendable, Codable {
    public var imageURLs: [URL]
    public var detail: CaptureDetail
    public var targetMetersPerUnit: Double?   // feeds ScaleFixer post-import
    public var profile: ValidationProfile      // arkit / arkit-strict
}

// Deterministic pre-flight: enough images? resolution consistent? overlap heuristic?
public struct CaptureQualityReport: Sendable {
    public let issues: [CaptureIssue]          // .tooFewImages, .mixedResolution, .lowOverlapHint …
    public var isAcceptable: Bool { issues.allSatisfy { !$0.isBlocking } }
}
public enum CaptureIssue: Sendable { /* … isBlocking flag per case … */ }

public protocol CapturePlanning: Sendable {
    func validate(_ r: CaptureRequest) -> CaptureQualityReport
    func plan(_ r: CaptureRequest) -> CapturePlan     // ordered BuildStep-style stages
}

// ConversionKit — the process seam (injected; excluded from coverage)
public protocol PhotogrammetryRunning: Sendable {
    func run(_ plan: CapturePlan) -> AsyncThrowingStream<CaptureProgress, Error>  // yields .progress / .modelReady(url)
}
public struct ObjectCaptureImporter: AssetImporter {
    public static let supportedExtensions = ["capture"]   // a folder/manifest of images
    public init(runner: PhotogrammetryRunning, planner: CapturePlanning)
    public func importAsset(at: URL, options: ImportOptions) async throws -> USDStage
}
```

The importer's output is opened through the normal `USDBridge` path, so the imported capture is immediately an editable stage; `targetMetersPerUnit` chains into the existing `ScaleFixer`, and the result runs through `ComplianceChecker`/`ExportGate` like any other asset.

## Algorithm

1. **Pre-flight (pure, `CaptureKit.validate`).** Count images (block < ~20; warn < ~50), check resolution consistency, warn on low estimated overlap (filename-order heuristic only — we don't decode SfM). Emit `CaptureQualityReport`; blocking issues stop before the expensive session.
2. **Plan (pure, `CaptureKit.plan`).** Map `CaptureDetail` → `PhotogrammetrySession.Request.Detail`; `.raw`/`.full` request the full PBR map set (baseColor/normal/AO/roughness), lower tiers request diffuse-only. Emit an ordered `CapturePlan` (validate → session → post-normalize → validate-output).
3. **Run (seam, `PhotogrammetryRunning.run`).** Invoke `PhotogrammetrySession` with the request, stream `.progress(Double)`; on `.modelReady` hand back the USDZ URL. This is the only non-deterministic, non-covered step — injected so tests use a fake runner returning fixture USDZ.
4. **Post-normalize (existing commands).** Open via bridge → optional `ScaleFixer` to `targetMetersPerUnit` → `defaultPrim`/naming quick-fixes → dirty stage the user can edit.
5. **Validate-output.** Run `ComplianceChecker` against the request `profile`; surface advisories (poly budget, texture sizes) in the import result. Never auto-launder.

Edge cases: USD floats are 32-bit (bake scale into transforms, not metadata drift); up-axis — `PhotogrammetrySession` outputs Y-up USDZ, matches our default, assert it; a session that fails/produces empty geometry surfaces a typed `ConversionError` with `recoverySuggestion` ("add more images / improve lighting").

**Follow-on 3 (GS→mesh), CUDA-free path:** ingest `.ply`/`.spz` → if the capture carries oriented points, run screened-Poisson (Open3D `create_from_point_cloud_poisson`, bundled Python) → decimate (`MeshKit`) → optional diffuse bake → USDZ. Full 2DGS/GOF/PGSR/gaustudio runs stay **offline/cloud** (CUDA + non-commercial rasterizer license); we import their mesh output. Be explicit in UI: diffuse-only, geometry may need cleanup.

## RealityKit export-profile behavior

- **Path 1 (photogrammetry):** output is mesh + `UsdPreviewSurface` already — passes `arkit`; `.raw` PBR maps survive; `ExportGate` flags oversized textures / poly budget as advisories like any asset. Nothing new to degrade.
- **Path 2 (splats):** **preview-only, never exported to USDZ.** QuickLook can't render splats; `ExportGate` treats a splat-preview resource as out-of-band (not written to `.usdz`). If we later adopt `UsdVolParticleField3DGaussianSplat`, it is authored only under the `lossless`/`full-USD` profile and flagged as dropped under `arkit`.
- **Path 3 (GS→mesh):** same as path 1 once meshed.

## Harness (lands in the SAME PR)

- **Invariants:** `CaptureKit` — property-based `validate` (monotonic: fewer images never *removes* a blocking issue), `plan` determinism (same request → same plan), detail→profile mapping table exhaustively asserted. Round-trip: imported fixture USDZ → open → save → open is a model-idempotence fixed point (existing `roundtrip` gate corpus gains a `capture-*` fixture).
- **Golden files:** committed fixture USDZ from a fake `PhotogrammetryRunning` (no real session in CI); golden `CapturePlan` JSON per detail level; for follow-on 3, golden `.usda` mesh from a fixed point-cloud fixture with pinned topology + analytic-volume check (`MeshKit` discipline).
- **Unit tests + coverage:** `CaptureKit` **100%** floor (new leaf); `ConversionKit` holds **100%** logic (the `PhotogrammetryRunning` seam excluded with `// coverage:disable — process seam`); `CLI` **95%** matrix (`capture` × {valid dir, too-few-images, missing dir} × {default,--json}); `SplatKit` **100%** (parse valid/truncated/wrong-endian PLY + `.spz`).
- **Fuzz corpus:** `SplatKit` parser fuzz (malformed headers, truncated buffers) added to the corpus; follow-on-3 Poisson output joins `MeshKit` `FuzzCorpus`.

## Rollout

1. **Governance first:** add `CaptureKit` to `dependency-lint.sh`, `architecture.md`, `testing.md`, `test-all.sh`, create test target (module-governance gate must be green).
2. **`CaptureKit` pure logic + tests** (validate/plan/gates, 100%).
3. **`ObjectCaptureImporter` + `PhotogrammetryRunning` seam**; fake runner + fixture USDZ; wire through `USDBridge` open + `ScaleFixer` + `ExportGate`.
4. **CLI `capture` subcommand** + matrix tests.
5. **EditorUI import sheet** (drop → detail → progress → validate → open); reuse batch/progress surfaces.
6. **Confirm `[VERIFY]` items**, then follow-on 2 (`SplatKit` + splat viewport) as a separate PR; follow-on 3 (GS→mesh) as a further PR.

## Risks & open questions

- **`[VERIFY]` macOS availability of native RealityKit splats** — decides follow-on-2 renderer (RealityKit component vs sibling `MTKView`). Confirm in SDK headers before starting follow-on 2.
- **`[VERIFY]` bundled `usd-core` exposes `UsdVolParticleField3DGaussianSplat`?** If not, UsdGeomPoints fallback or defer native splat-in-USD.
- **No mature reconstructive PBR** — path 1 `.raw` gives real PBR maps from `PhotogrammetrySession`; the GS→mesh path (3) is diffuse-only. Set UI expectations; don't over-promise PBR from splats.
- **Capture quality is user-dependent** — the pre-flight gate and capture guidance are part of the feature, not polish. Decide how strict blocking thresholds are (product call).
- **`PhotogrammetrySession` hardware floor** (Apple silicon, or Intel + ≥16GB/AMD ≥4GB VRAM) — surface a clear unsupported-hardware message; the pure planner is testable everywhere, only the seam needs the hardware.
- **Offline GS→mesh story** — ship a documented external recipe vs a hosted helper; the Inria non-commercial rasterizer license forbids bundling a trainer. Human/product decision.

## Acceptance criteria

- [ ] Drop ~50 photos in the import sheet → get an editable, `arkit`-valid textured USDZ, fully in-app, no CUDA/third-party.
- [ ] `openusdz capture <dir> <out.usdz> --detail medium` produces the same asset headless; CLI matrix green.
- [ ] `CaptureKit` at 100% coverage; `ConversionKit` holds 100% logic (seam excluded + annotated); imported fixture passes the `roundtrip` model-idempotence gate.
- [ ] Import degrades correctly under `arkit`/`arkit-strict` via `ExportGate` (advisories surfaced, never auto-laundered).
- [ ] (Follow-on 2) splat preview renders in-app and is provably excluded from exported `.usdz`.
