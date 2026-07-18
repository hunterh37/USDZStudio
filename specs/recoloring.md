# Recoloring Specification — Part-Level Live Recolor

## Overview

Recolor any mesh piece of a USDZ — a wheel, a bumper, a fabric panel — with live viewport feedback and color-accurate results, including parts whose color comes from albedo *textures*. This is a flagship differentiator: no tool in the USDZ ecosystem does perceptual texture recoloring. Lives primarily in ConversionKit's texture pipeline (`RecolorEngine`) + EditingKit commands + an EditorUI panel.

Delivered in two tiers (see ROADMAP): **Tier A** (solid colors + shared-material handling, Phase 3) and **Tier B** (perceptual texture recolor + masks + calibrated accuracy, Phase 4.5).

## Tier A — Solid-Color Recolor & Material Uniquing

### Behavior
- Select part(s) → Recolor panel (inspector tab) → color picker; `diffuseColor` updates live while dragging, commits one undo step on release.
- **Auto-uniquing:** if the bound material is shared with unselected prims, the app transparently duplicates it (`<MaterialName>_<PartName>`), rebinds the selection, then edits the copy — surfaced in the panel as "Material was shared with 4 other parts — made unique" with an undo-all affordance. One `CompositeCommand`.
- **GeomSubset granularity:** subsets appear in the outliner as children of their mesh and are selectable/recolorable exactly like prims (RealityKit renders per-subset bindings).
- Scope choice when selection has mixed sharing: "This part only / All parts using this material."

### Commands
| Command | Composite of |
|---|---|
| `UniquifyMaterialCommand` | duplicate material prim + rebind selection |
| `RecolorPartCommand` (solid) | optional uniquify → `SetMaterialInputCommand(diffuseColor)` |

## Tier B — Perceptual Texture Recolor

### The problem
Tinting a texture (multiply) darkens and muddies; it cannot turn red leather blue. Correct recolor must preserve the texture's *detail* (lightness/chroma variation = grain, weave, shading) while remapping its color.

### RecolorEngine algorithm
1. Decode albedo → linear RGB → **OKLab/OKLCh**.
2. Within the target region (mask, see below): compute region's chroma/hue statistics; remap hue to target hue; rescale chroma toward target chroma preserving per-pixel deviation; preserve per-pixel lightness (optional lightness bias slider for light↔dark recolors, with detail-preservation floor).
3. Convert back → re-encode (PNG lossless intermediate; output format per preset; never re-encode JPEG generationally — engine always works from the highest-quality source in the package).
4. All color-space conversions explicit and tagged: texture color space read from `sourceColorSpace` (fallback: heuristic + user override), sRGB↔linear correctness unit-tested against reference values.

Implementation: Metal compute kernel (live path, 2K texture at slider-drag rates on Apple Silicon) with a CPU/vImage fallback (also the reference implementation for tests).

### Masks (multi-color textures)
- **Auto-segmentation:** k-means/color-similarity clustering in OKLab proposes regions ("fabric" vs. "printed logo"); user picks target region(s) by clicking the 3D part in the viewport — the hit UV + similarity threshold seeds the mask.
- **Mask refinement:** threshold slider + brush add/remove on a 2D texture view (flat editor, not 3D painting — v1 scope boundary).
- Masks stored as grayscale PNGs in an app-support cache keyed by texture hash; optionally embedded in the USDZ under `dicyanin:` custom data for re-editing later.

### Live preview
- While dragging: engine output written to the RealityKit material's texture resource (double-buffered, debounced to display refresh). Commit on release = `RecolorPartCommand(textured)` — composite: uniquify material → uniquify texture file (new name in package) → write recolored texture → rebind path. Fully undoable (original texture retained in package until save).

### Calibrated accuracy mode
- Target input as sRGB/hex/Display-P3 (color-managed picker; NSColorSampler eyedropper).
- **"Match rendered color":** solves for the albedo that *renders* as the target under a neutral illuminant: render part offscreen under calibration IBL → sample achieved color → iterate correction (≤3 passes, converges since response is near-linear). Handles the albedo-vs-lighting gap; UI copy states colors are matched under Neutral Studio lighting.
- Metallic-aware: when `metallic > 0.5`, recolor also biases toward tinting via the reflection path and warns that metallic color perception is environment-dependent.
- ΔE (OKLab) readout in the panel: target vs. achieved rendered color.

## Scripting & Batch
- `app.recolor(selection, target="#FF6B00", mode="calibrated")` exposed to the Python console; batch script `recolor_batch.py` ships in the library (the e-commerce "rebrand 200 SKUs" workflow).
- CLI: `openusdz recolor in.usdz --prim /Car/Body --color '#FF6B00' --mode calibrated -o out.usdz`.

## Testing (per specs/testing.md — logic is 100%-gated)
- RecolorEngine: reference-value unit tests for every color-space conversion; property tests (recolor to same color = identity within ε; lightness preservation invariant).
- GPU vs. CPU implementation parity test (same input → ΔE < 0.5 per pixel).
- Golden-image: recolored corpus textures vs. approved references; calibrated mode asserts achieved ΔE < 2.0 on test scenes.
- Round-trip: recolor → undo → save → usddiff clean; recolor → save → reopen → texture bytes stable.
