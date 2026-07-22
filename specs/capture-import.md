# CaptureKit Specification — Real-World Capture (Photos → USDZ)

Turn a folder of photographs into a **validated, editable USDZ** inside the app,
by wrapping Apple's native `PhotogrammetrySession` as a first-class importer with
a staged, quality-gated pipeline. Companion research:
`research/topics/gaussian-splatting-to-usdz/`. This is **Phase 2.5 — Capture
Import**, extending the Phase 2 conversion pipeline; it reuses the
`AssetImporter`/`ConversionStage` protocols, the batch engine, and
`ComplianceChecker`/`ExportGate` rather than inventing a parallel path.

## Why this shape

The design principle is the one `specs/sculpt-pipeline.md` already establishes:
**deterministic code does all mechanical and policy work; the only
non-deterministic, non-covered step is the reconstruction itself, isolated behind
an injected seam.** Photogrammetry is the pragmatic state of the art for our
target format: `PhotogrammetrySession` runs on Apple-silicon macOS with no CUDA
and no third-party libraries, and its output is *already* `UsdGeomMesh` +
`UsdPreviewSurface` USDZ — so a capture degrades trivially under the `arkit`
export profile and needs no bridge from an alien representation. Gaussian-splat
reconstruction is deliberately **not** this feature (splats can't render in
QuickLook/USDZ, mature splat→mesh gives diffuse-only geometry, and the reference
trainers are CUDA-only with a non-commercial rasterizer license); it is a
forward-looking follow-on tracked in the research plan, not here.

## Principles

1. **Native-first, CUDA-free.** The only reconstruction backend in scope is
   `PhotogrammetrySession`. No bundled trainer, no GPU compute we don't already
   ship.
2. **Deterministic outside the seam.** Pre-flight validation, detail→profile
   mapping, plan generation, and output validation are pure functions; the
   session call is the single injected `PhotogrammetryRunning` seam.
3. **Output is a normal stage.** A finished capture is opened through `USDBridge`
   like any other asset — immediately editable, undoable, exportable, gated.
4. **Honest about quality.** Capture quality is user-dependent; the pre-flight
   gate and capture guidance are part of the feature, not polish. We never
   silently "fix" a bad capture.

## Module split

- **`CaptureKit`** — new **pure-Swift leaf** (deps `USDCore` + `MeshKit`, 100%
  floor), a sibling to `MeshKit`/`QuickLookKit`. Holds the request/quality model,
  input validation, the detail→profile mapping, the acceptance gates, and the
  `CapturePlan` (an ordered `BuildStep`-style stage list). It authors no stage and
  runs no session. Adding it obeys the module-governance ritual in the same PR
  (`dependency-lint.sh` policy entry, this spec + `architecture.md` layout/rules,
  `specs/testing.md` floor row, test target, `test-all.sh` entry).
- **`ConversionKit`** — the `ObjectCaptureImporter: AssetImporter` and the
  `ConversionStage`s that realize a `CapturePlan`, driving the
  `PhotogrammetryRunning` seam and chaining the result through open →
  `ScaleFixer` → validate. New dependency edge `ConversionKit → CaptureKit` (leaf)
  is legal.
- **`EditorUI`** — the capture import sheet.
- **`CLI`** — the headless `openusdz capture` subcommand.

Dependency edges (all legal per `specs/architecture.md`):

```
ConversionKit ─▶ CaptureKit ─▶ {USDCore, MeshKit}
EditorUI ─▶ ConversionKit         (existing)
CLI ─▶ {ConversionKit, CaptureKit} (existing kit edges)
```

The `PhotogrammetrySession` call is a **process/framework seam** injected behind
`PhotogrammetryRunning`, excluded from coverage with an inline
`// coverage:disable — reconstruction seam` annotation, exactly as the `usdrecord`
and Python-bridge seams are.

## Supported input

| Input | Notes |
|---|---|
| A folder of images (`.heic`/`.jpg`/`.png`) | Primary. A `.capture` manifest (folder + optional per-image gravity/depth) is the importer's `supportedExtensions` handle. |
| Images + depth/gravity metadata | Optional; improves absolute scale and quality when present (LiDAR-captured HEIC). Not required. |
| Object Capture "images + `.objcap`" session dir | Best-effort passthrough of an on-device iOS capture. |

Hardware floor is Apple silicon (or an Intel Mac with ≥16 GB RAM and an AMD GPU
with ≥4 GB VRAM). The **pure planner is testable everywhere**; only the seam needs
the hardware, and an unsupported host surfaces a typed `ConversionError` with a
clear `recoverySuggestion` rather than failing opaquely.

## Data model / API

```swift
// CaptureKit — pure, Sendable, Codable, 100%-covered.
public enum CaptureDetail: String, Sendable, Codable {
    case preview, reduced, medium, full, raw   // maps to PhotogrammetrySession.Request.Detail
}

public struct CaptureRequest: Sendable, Codable {
    public var imageURLs: [URL]
    public var detail: CaptureDetail
    public var targetMetersPerUnit: Double?     // chains into the existing ScaleFixer
    public var profile: ValidationProfile        // .arkit / .arkitStrict
}

public enum CaptureIssue: Sendable, Equatable {
    case tooFewImages(count: Int, minimum: Int)  // blocking
    case mixedResolution                          // blocking
    case lowOverlapHint                           // advisory
    case unsupportedImageFormat(URL)              // blocking
    public var isBlocking: Bool { /* … */ }
}

public struct CaptureQualityReport: Sendable {
    public let issues: [CaptureIssue]
    public var isAcceptable: Bool { issues.allSatisfy { !$0.isBlocking } }
}

public struct CapturePlan: Sendable, Codable {          // ordered BuildStep-style stages
    public let stages: [CaptureStageID]                 // validate → session → normalize → validateOutput
    public let sessionDetail: String                    // resolved PhotogrammetrySession detail token
    public let requestsPBRMaps: Bool                    // .full/.raw → normal/AO/roughness
}

public protocol CapturePlanning: Sendable {
    func validate(_ r: CaptureRequest) -> CaptureQualityReport
    func plan(_ r: CaptureRequest) -> CapturePlan
}

// ConversionKit — the injected seam (excluded from coverage).
public enum CaptureProgress: Sendable {
    case progress(Double)                                // 0…1
    case modelReady(url: URL)                            // finished USDZ
}
public protocol PhotogrammetryRunning: Sendable {
    func run(_ plan: CapturePlan, images: [URL]) -> AsyncThrowingStream<CaptureProgress, Error>
}

public struct ObjectCaptureImporter: AssetImporter {
    public static let supportedExtensions = ["capture"]  // a folder/manifest of images
    public init(runner: PhotogrammetryRunning, planner: CapturePlanning)
    public func importAsset(at url: URL, options: ImportOptions) async throws -> USDStage
}
```

## Pipeline model

The importer realizes the `CapturePlan` as a `ConversionStage` sequence, so it
shares the transparent, logged, per-stage machinery of the conversion pipeline:

1. **`validate`** (pure) — `CaptureKit.validate` builds the `CaptureQualityReport`.
   Block on `< ~20` images, mixed resolution, or an unsupported image format;
   advise on `< ~50` images and low estimated overlap. Blocking issues stop
   **before** the expensive session.
2. **`session`** (seam) — `PhotogrammetryRunning.run` invokes
   `PhotogrammetrySession` with the resolved detail, streams `.progress`, and
   yields `.modelReady(url)`. The only non-deterministic, non-covered stage.
3. **`normalize`** (existing commands) — open the produced USDZ via `USDBridge`;
   assert Y-up (PhotogrammetrySession emits Y-up, matching our default); optional
   `ScaleFixer` to `targetMetersPerUnit`; `defaultPrim`/name quick-fixes. Result
   is a dirty, editable stage.
4. **`validateOutput`** (pure) — run `ComplianceChecker` against
   `request.profile` → advisories (poly budget, texture sizes) surfaced in the
   import result. Never auto-launder the verdict.

### Detail → session mapping

| `CaptureDetail` | Session detail | Maps authored |
|---|---|---|
| `preview` | preview | diffuse only (fast, in-app orbit) |
| `reduced` | reduced | diffuse only |
| `medium` | medium | diffuse (+ normal) |
| `full` | full | baseColor + normal + AO + roughness |
| `raw` | raw | full PBR map set, max fidelity |

`requestsPBRMaps` is `true` for `.full`/`.raw`; those tiers produce a real
`UsdPreviewSurface` metallic-roughness set. Lower tiers produce diffuse-only and
are flagged as such in the result so the user isn't surprised by a flat material.

## RealityKit export-profile behavior

Capture output is mesh + `UsdPreviewSurface` from the start, so it passes `arkit`
without a degradation step. `.raw`/`.full` PBR maps survive a RealityKit
round-trip; `ExportGate`/`ComplianceChecker` flags oversized textures and poly
budget as **advisories** exactly as for any imported asset, and the deliberate
"Export Anyway" override permits but never launders the verdict. There is no
splat, point-field, or exotic construct introduced here — nothing new to drop
under `arkit`/`arkit-strict`.

## Batch & CLI

- **Batch:** a capture job is a `BatchJob` variant — a parent folder of per-object
  image subfolders → preset detail → output folder, reusing the concurrency-limited
  task group and `report.csv`/`report.json` (per-object status, warnings, tri
  count, texture memory, output size). Resumable by content hash.
- **CLI:** `openusdz capture <images-dir> <out.usdz> --detail medium
  [--profile arkit] [--meters-per-unit 1.0] [--json]`. Same pipeline headless;
  exit code follows the validate verdict, and `--json` mirrors the human report
  diagnostic-for-diagnostic (matching the existing `validate` contract).

## UI

- **Capture import sheet:** drop an image folder → detail-level picker (with a
  plain-language note on what each tier produces and the diffuse-only caveat) →
  pre-flight report (blocking issues disable Start; advisories are shown but
  non-blocking) → live progress → on completion, open the stage and present the
  `ComplianceChecker` advisories inline. Reuses the conversion sheet's log pane.
- **Capture guidance:** a short in-sheet checklist (equidistant angles, diffuse
  lighting, high overlap, multiple heights) surfaced when the overlap/near-minimum
  advisories fire — quality guidance is part of the feature.

## Testing (harness lands in the SAME PR)

- **`CaptureKit` — 100% floor.** Property-based `validate` (monotonic: removing
  images never *clears* a blocking issue); `plan` determinism (same request → same
  `CapturePlan`); the detail→session table asserted exhaustively; every
  `CaptureIssue.isBlocking` branch covered.
- **`ConversionKit` — 100% logic.** `ObjectCaptureImporter` driven by a **fake
  `PhotogrammetryRunning`** that streams progress and returns a committed fixture
  USDZ (no real session in CI). The seam itself is excluded + annotated.
- **Round-trip.** The fixture capture joins the `roundtrip` gate corpus as
  `capture-*`: open → save → open is a model-idempotence fixed point; the
  `EXPECTATIONS` table records its status like every other corpus file.
- **CLI matrix.** `capture` × {valid dir, too-few-images, missing dir,
  unsupported-format} × {default, --json}; exit codes and JSON↔human agreement
  asserted.
- **Golden files.** Golden `CapturePlan` JSON per detail level; the fixture USDZ's
  imported stage structure pinned.
- **EditorUI.** Snapshot the sheet's report/progress/completion states; the
  drop→detail→import→open flow joins the XCUITest smoke matrix (Phase T1).

## Roadmap placement

New **Phase 2.5 — Capture Import**, sequenced after Phase 2 (Conversion) and
independent of the authoring phases. It unblocks a category no open USDZ editor
covers (in-app photo→editable-USDZ) and depends only on shipped machinery
(`AssetImporter`, batch engine, `ScaleFixer`, `ExportGate`, `USDBridge` open).

## Risks & open questions

- **Hardware floor** — surface a clear unsupported-host message; the pure planner
  stays testable on any CI runner because the seam is injected.
- **Capture-quality thresholds** — the exact blocking minimums (image count,
  resolution consistency) are a product call; start conservative and tune against
  real captures.
- **Diffuse-only lower tiers** — set expectations in the UI; don't imply full PBR
  from `.preview`/`.reduced`.
- **On-device iOS `.objcap` passthrough** — best-effort in v1; the primary path is
  a plain image folder reconstructed on the Mac.
- **Follow-ons** (separate PRs, tracked in the research plan): a splat *preview*
  viewport (`SplatKit` leaf + `ViewportKit`), and a CUDA-free GS→mesh importer —
  both explicitly out of this spec's scope.
