# Real-photo baseline fixtures (#94)

This directory holds committed real-photo baselines for the sculpt-accuracy
program. Each fixture is JSON decoding to `RealPhotoFixture` (see
`SculptKit/RealPhotoBaseline.swift`).

## Status: pending a real asset

`aventador.blueprint.json` is a **blueprint**, not a reproducible fixture. It
records the §2 analysis targets — the numbers a committed real reference must
reproduce within ±0.01 — but carries **no pixels** (`width`/`height` are 0 and
the `referenceBase64` / `handMaskBase64` / per-pass `renderBase64` payloads are
absent). `RealPhotoBaseline.reproduce` therefore reports it as `pending` rather
than fabricating a measurement. The `pose` is a placeholder to be replaced by
the real recorded pose when the asset lands.

The §2 targets it freezes (from `specs/sculpt-accuracy-analysis.md`):

| pass            | reference | aggregate | silhouetteIoU | ssim  | luminance |
|-----------------|-----------|----------:|--------------:|------:|----------:|
| blockout-raw    | raw photo |     0.170 |         0.166 | 0.028 |     0.513 |
| blockout-matte  | matte     |     0.348 |         0.420 | 0.145 |     0.582 |
| structural      | matte     |     0.483 |           —   |   —   |       —   |
| material        | matte     |     0.411 |           —   |   —   |       —   |

## Committing a real reference

To turn the blueprint into a reproducible fixture, add a JSON file to this
directory with:

- `name`, and the recorded `pose` (`azimuthDegrees`, `elevationDegrees`).
- `width`, `height` of the images.
- `referenceBase64`: the reference photo as RGBA8 (`width*height*4` bytes),
  base64-encoded. Decode the source photo with the AgentMCP/CLI ImageIO layer
  (SculptKit itself decodes no pixels — guardrail) and hand the raw bytes here.
- `handMaskBase64`: the **hand-labelled** foreground mask, one alpha byte per
  pixel (`width*height` bytes), base64-encoded.
- one `passes` entry per row, each with the pass render as `renderBase64` plus
  the frozen `baseline` numbers.

`RealPhotoBaselineTests.blueprintFreezesSection2Targets` asserts the blueprint's
frozen numbers; `realFixturesReproduceWithinTolerance` will automatically pick
up any reproducible fixture dropped here and assert it lands within ±0.01. Until
such an asset is committed, that test passes vacuously over the pending
blueprint (documented, not faked).
