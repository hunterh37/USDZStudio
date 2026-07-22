---
name: promo-image
description: Produce a marketing/promo image for OpenUSDZEditor — the "before/after" split card (untextured primitive → photoreal textured render) and the photoreal orthographic sphere/globe render behind it. Use when asked to make a promo, hero shot, before/after card, launch image, README banner, or social/marketing visual for the app. Renders with pure Python (numpy + Pillow) in the bundled usd-core runtime; does NOT depend on the app's preview renderer.
---

# OpenUSDZEditor promo images

Two reusable pieces, each a standalone script under `scripts/`:

1. `render_sphere.py` — a photoreal, marketing-grade **orthographic globe/sphere** render from any equirectangular texture (Earth, moon, marble, gas giant, any planet map). This is the "hero object."
2. `promo_card.py` — the branded **before/after split card** that frames a plain "before" render next to a polished "after" render, with headline, panel labels, an arrow badge, and footer.

Both run under the bundled runtime and need only `numpy` + `Pillow`:

```sh
PY=Resources/Python/runtime/bin/python3
"$PY" -m pip install --quiet numpy Pillow   # one-time; usually already present
```

## Why pure Python and not the app renderer

The app's `render_views` / native SceneKit renderer **cannot display textured
`UsdPreviewSurface` materials** (see issue #90 — it only applies constant
`diffuseColor`). So a texture-mapped asset renders grey there. For a *promo*
we want the texture to actually show, so we render the equirectangular map onto
the sphere ourselves. This is faithful: it's the same texture and the same
geometry the USD asset binds — we're just doing the shading the preview renderer
can't yet. Use the app only for the genuine **"before"** grey primitive (via the
MCP `render_views` on an untextured `create_mesh` sphere), which is exactly the
state we're contrasting against.

## The house style (keep these constant so promos look like a set)

Sphere render (`render_sphere.py`):
- **Orthographic** projection, sphere fills ~86% of a square frame, on near-black space.
- Equirectangular **bilinear** sampling (never nearest — nearest gives blocky UV artifacts).
- Work in **linear light**: sRGB→linear on the albedo, shade, then linear→sRGB out.
- Lighting = **wrap-Lambert** (`(N·L + 0.18)/1.18`) for a soft day/night terminator, ~0.08 night-side ambient so the dark limb never goes pure black.
- **Atmosphere**: an inner limb haze (blue, brightest on the lit side) plus an outer **glow ring** just beyond the disc, biased toward the light direction. Accent blue `(0.30, 0.55, 1.0)`.
- Slight axial **tilt** (~23°) and a chosen center longitude so recognizable geography faces the light. Default light comes from upper-left-front.
- **Supersample 2×** then downscale (Lanczos) for clean edges.
- **No cloud layer** unless a genuinely high-res cloud map is supplied — the stock NASA 1k cloud PNG is a low-quality indexed image and reads as blocky garbage. Cloudless "blue marble" is the cleaner default.
- **No giant ocean specular blob.** A broad Blinn highlight on an orthographic sphere reads as a white smudge; leave the glint off (or keep it very tight + faint) for a clean look.

Before/after card (`promo_card.py`):
- Dark **vertical-gradient** background (`#0D0F16` → `#06070B`).
- One accent color everywhere: **`#5696FF`** (kicker text, AFTER border, AFTER label, arrow badge).
- Two **rounded-corner square panels** (radius ~28px): BEFORE gets a muted grey border, AFTER gets the accent border.
- A circular **arrow badge** (`→`) straddling the gap between panels, accent fill + white ring.
- Header: small-caps **kicker** ("OPENUSDZ EDITOR") in accent, then a big **headline**, then a one-line **subhead** in muted grey.
- Panel labels below each: `BEFORE` / `AFTER` + a small caption line.
- Footer: left = tech tagline ("Open source · SwiftUI + RealityKit + OpenUSD · macOS"), right = a call to action.
- Prefer system fonts (`SFNS.ttf` / Helvetica). Avoid emoji in `ImageDraw.text` — Pillow renders most as tofu; use a plain `★` glyph if you want a star.

## Two card modes (`promo_card.py --mode`)

- **`beforeafter`** (default): grey primitive (left, `--before`) → textured render
  (right, `--after`). The classic capability card.
- **`reference`**: a **real reference photo** (left, `--reference`, labelled
  `REFERENCE`) → the **reconstructed 3D render** (right, `--after`, labelled
  `RECONSTRUCTED`). Use this whenever the task is "build/reconstruct X **from a
  reference image**" — it is the honest, compelling framing for a photo→3D agent.

**If the task is "reconstruct/build X from a reference photo", you MUST:**
1. Actually **obtain the reference file** (fetch/download the real image the model
   is reconstructed from), and
2. Compose with `--mode reference --reference <that file> --after <your render>`.

Non-square references are cover-fit (center-cropped) automatically, so any aspect
ratio frames cleanly without distortion.

### Honesty guardrails (non-negotiable)

- **Never fabricate a "reference."** Do not pass one of our own renders (or a
  model-imagined image) as `--reference`. The left panel must be a genuine
  external reference the reconstruction was actually based on.
- **Never claim a reference photo was used unless a real image file was fetched
  and passed to the card.** If a web/stock fetch fails, say so plainly and fall
  back to `--mode beforeafter` (grey→textured) — do not imply a reference existed.

## Standard workflow

1. **Fetch a reference texture.** Equirectangular maps live on allowed domains, e.g. the three.js planet textures on `raw.githubusercontent.com`. Read it with the Read tool to confirm it's a clean equirect map before rendering.
2. **Author the textured asset in the live stage** (optional but nice — makes the promo backed by a real USD asset): build a UV sphere with correct `st`/normals, bind a `UsdUVTexture` → albedo `UsdPreviewSurface`, package as `.usdz`. See `scripts/build_textured_sphere.py` (run via the MCP `run_script` from the bundled scripts dir, or headless). Import it with `import_asset` — the `.usdz`/`.usda` path preserves types; **glTF/GLB/OBJ imports get flattened to unreadable `double[]` points** (vertices=0), so prefer USDZ/USDA.
3. **Capture the BEFORE.** In the live stage, `create_mesh` a plain sphere and `render_views` it (persp, 640px) → grey primitive. Save that PNG.
4. **Render the AFTER** with `render_sphere.py` on the same texture.
5. **Compose** with `promo_card.py`, passing the before + after PNGs and your copy.
6. **Deliver** the PNGs (and the `.usdz`) to `/mnt/user-data/outputs` or wherever the user asks (they may say "Desktop").

## Commands

```sh
PY=Resources/Python/runtime/bin/python3
SK=.claude/skills/promo-image/scripts

# After: photoreal globe from an equirectangular albedo
"$PY" "$SK/render_sphere.py" --texture earth_8k.jpg --out after.png \
      --size 1600 --tilt 23.4 --center-lon -30

# Before/after card (default mode)
"$PY" "$SK/promo_card.py" --before before.png --after after.png --out promo.png \
      --title "Texture anything. Natively." \
      --subtitle "Import a reference photo and wrap real geometry with a full PBR material — right in the editor." \
      --after-caption "Photoreal, equirectangular-mapped globe"

# Reference → reconstructed card (photo→3D reconstruction promos)
"$PY" "$SK/promo_card.py" --mode reference --reference photo.jpg --after render.png \
      --out promo.png --title "From one photo to a 3D asset."
```

Both scripts have `--help`. `render_sphere.py` also takes `--light x,y,z`,
`--bg r,g,b`, `--ss` (supersample), and `--fill` (disc fraction). `promo_card.py`
takes `--kicker`, `--before-caption`, `--footer-left`, `--footer-right`, `--accent`.

## Cleanup

Write scratch renders under `.tmp/` (git-ignored), not into tracked dirs.
If you drop a script into `Resources/Python/scripts/` to run it through the MCP
`run_script` (that dir is where `_harness` resolves), **remove it afterward** —
other agents share this working tree.
