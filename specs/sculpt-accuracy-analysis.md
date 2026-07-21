# Sculpt-from-Image Accuracy — Measurement-Driven Improvement Plan

Status: analysis / planning. Author: reconstruction worklog, 2026-07-21
(Lamborghini Aventador from an in-the-wild reference photo).

This document records **measured** results from a real end-to-end
sculpt-from-image run and derives a precise, testable program for improving
reconstruction accuracy. Every proposal below is tied to an observation with a
number, not a guess. The GitHub issues that track the work each link back to a
section here.

## 1. What was run

Reference: a CC-BY-SA street photo of a green Lamborghini Aventador S, 5472×3648,
front-left 3/4 view, driver scissor door open (busy Champs-Élysées background:
pedestrians, buildings, road, reflections).

Pipeline: `sculpt_probe → sculpt_assess → sculpt_author_spec` (29 components: body
shells, cabin, windshield + side glazing, 4 wheels = tire + rim + caliper, front
splitter, mirrors; 6 PBR materials) → `sculpt_build_pass` per locked pass →
`sculpt_comparison_sheet` (deterministic similarity) → `sculpt_review`.

Assessment output: `objectClass=hybrid`, `complexity=5`, policy
`minScore=0.8`, `similarityFloor=0.55`, `requireMaterials=true`.

## 2. Measured similarity (the evidence)

`measuredSimilarity` = weighted blend of silhouette IoU + SSIM + luminance
correlation on a fixed **64×64** resample (SculptKit `ImageSimilarity`).

| Pass / condition | reference used | aggregate | silhouetteIoU | SSIM | luminance |
|---|---|--:|--:|--:|--:|
| blockout, persp render, **raw photo** | raw JPEG | **0.170** | 0.166 | 0.028 | 0.513 |
| blockout, tight-cropped render, clean-ish matte | colour matte | **0.348** | 0.420 | 0.145 | 0.582 |
| blockout, best of 16 angles | grey **silhouette** | **0.619** | — | — | — |
| structural (placed), best of 16 angles | grey **silhouette** | **0.483** | — | — | — |
| structural (placed), best angle | colour matte | **0.460** | — | — | — |
| material (green), best of 16 angles | colour matte | **0.411** | — | — | — |

These are the regression baselines. Any accuracy change must be measured against
them (same reference, same angle-search, same metric).

## 3. Findings (root causes, each measured)

### F1 — Reference segmentation is the dominant error source
The raw photo scored IoU 0.166 vs 0.420 after matting — a **2.5× swing** driven
purely by how the reference foreground is isolated, not by the model. Automatic
colour-threshold segmentation (green-hue ∪ dark, largest connected component,
morphological close / scanline fill) was unreliable: glossy green reflections,
green background (awning, foliage), dark windows, and the busy street repeatedly
leaked into or over-filled the mask (produced masks with `fill_frac` 0.57–0.73;
visual inspection showed background bleed and over-solidified rooflines).
**Segmentation quality gates everything downstream.**

### F2 — The silhouette metric rewards solid blobs over realistic geometry
Against the (over-filled) silhouette, the **origin-collapsed blockout blob scored
0.619 but the correctly-placed structural car scored 0.483** — the blob beat the
real car. Cause: a scanline/over-filled reference silhouette has no interior
concavities (wheel gaps, under-body, cabin cut-ins), so a dense convex blob
maximises IoU while a faithful, gapped car is penalised. The signal is
**anti-correlated with fidelity** in this regime. This is a metric-methodology
defect, independent of the model.

### F3 — Colour metric is unfair to untextured passes (partially fixed)
Grey clay renders (blockout/structural/formRefinement) score SSIM 0.03–0.15
against a colour photo regardless of geometric fidelity. PRs #76/#78 already
deferred the deterministic floor to the `material` pass for this reason, but the
blended metric still mixes appearance into what is conceptually a shape check.

### F4 — Viewpoint was brute-forced, not estimated
Comparison angle was chosen by rendering a 16-entry azimuth/elevation grid and
keeping the best IoU. There is no estimate of the reference camera pose, so IoU
is penalised by pose mismatch that is confounded with shape error. Best angles
drifted (125°, 305°, 325°) run-to-run, indicating the search, not the geometry,
was moving the number.

### F5 — Geometry is limited to 5 primitives + `inset`
The spec builds from box/cylinder/cone/sphere/plane and one refinement op
(`inset`). An Aventador's defining wedge, hexagonal intakes, sharp shoulder
lines and wheel arches cannot be represented, capping achievable silhouette IoU.
Renders also read as "lumpy" (subdivision rounding) and produced 24
`mesh.normals` info diagnostics ("no normals authored; shading will be
faceted"), degrading any appearance-based metric.

### F6 — 64×64 resample is coarse
Silhouette IoU / SSIM computed on a 64×64 grid discards fine contour detail
(door gaps, mirror stalks, splitter). Sensitivity of the metric to resolution is
unquantified.

## 4. Improvement program (scientific, testable)

Ordered by measured leverage. Each item states a hypothesis, method, and
**acceptance criterion expressed as a number against the §2 baseline**.

- **P0 — Ground-truth eval harness (foundation).** Without labelled data we are
  tuning blind. Build a small benchmark: N≥10 reference images with (a)
  hand-labelled foreground masks and (b) recorded camera poses; plus a
  correlation study of `measuredSimilarity` vs human ranking. Freeze the §2
  numbers as the baseline. *Acceptance:* harness reports per-image mask-IoU and
  pose error; metric-vs-human Spearman ρ reported.

- **P1 — Robust reference segmentation (addresses F1).** Replace the
  colour-threshold heuristic with a real matting stage (evaluate: GrabCut,
  saliency + guided filter, or a learned matte) producing a clean alpha.
  *Acceptance:* produced-mask IoU ≥ 0.95 vs hand labels on the P0 set; blockout
  raw→matted IoU swing reproduced and improved (> 0.42 → target ≥ 0.6 on the
  Aventador reference).

- **P2 — Concavity-preserving, shape-vs-appearance metric (addresses F2, F3, F6).**
  Stop over-filling the reference silhouette; preserve interior gaps. Split the
  metric into a **shape** term (silhouette IoU + symmetric contour/chamfer
  distance) and an **appearance** term (used only from `material`). Raise the
  resample resolution and report sensitivity. *Acceptance:* placed structural
  car scores **strictly higher** than the origin-collapsed blockout blob on the
  shape metric (reverses the 0.619 > 0.483 anomaly); monotonicity test passes.

- **P3 — Camera-pose alignment (addresses F4).** Estimate the reference view
  (azimuth/elevation/FOV) — e.g. from wheel-ellipse geometry / vanishing lines —
  and render the model from the matched pose before comparison; keep a
  coarse-to-fine residual search. *Acceptance:* report pose residual; ablation
  showing IoU gain attributable to pose vs shape on the P0 set.

- **P4 — Geometry expressiveness (addresses F5).** Extend refinement ops beyond
  `inset` (bevel/chamfer, extrude, loft between cross-sections, simple booleans)
  and/or lofted body cross-sections; fix subdivision rounding. *Acceptance:*
  measured silhouette-IoU ceiling on the Aventador reference rises from the
  ~0.46 primitive plateau to a target ≥ 0.65 with pose+segmentation held fixed.

- **P5 — Author real normals (addresses F5 shading).** Emit vertex normals so
  renders are correctly shaded (removes the 24 `mesh.normals` diagnostics).
  *Acceptance:* zero `mesh.normals` info diagnostics; appearance-term SSIM
  improvement quantified at the `material` pass.

## 5. Non-goals / guardrails

- Do **not** lower `policy.similarityFloor`, weaken gates, or fake review scores
  to make numbers pass. Accuracy work must move the *measured* signal on the P0
  harness, not the threshold.
- Keep SculptKit pixel-decode-free (matting/pose live in the AgentMCP/executor
  layer, like `RasterLoader`).
