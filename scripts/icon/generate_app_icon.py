#!/usr/bin/env python3
"""
generate_app_icon.py — 100% CLI-generated macOS app icons for OpenUSDZEditor.

No design files, no external services: every pixel is computed from the repo's
own design tokens (Packages/DicyaninDesignSystem — blue-graphite dark palette,
X/Y/Z axis gizmo tints). Three scripted variations, each rendered at high
supersampling and downscaled with Lanczos for crisp anti-aliasing, then packed
into a macOS .appiconset + .icns.

    python3 scripts/icon/generate_app_icon.py            # all three variants
    python3 scripts/icon/generate_app_icon.py --variant cube
    python3 scripts/icon/generate_app_icon.py --pick wireframe   # also writes AppIcon.appiconset + .icns

Pure Pillow. No native/system dependencies beyond Pillow + macOS iconutil.
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover
    sys.exit("Pillow is required:  python3 -m pip install --user Pillow")

# ---------------------------------------------------------------------------
# Design tokens — mirrored from Packages/DicyaninDesignSystem/.../Tokens.swift
# ---------------------------------------------------------------------------
VIEWPORT_BG   = "#0D0F13"
WINDOW_BG     = "#14161C"
PANEL_BG      = "#1A1D24"
SURFACE_ELEV  = "#20242D"
SURFACE_HOVER = "#262B35"
PANEL_BORDER  = "#2B303B"
TEXT_PRIMARY  = "#E7EAF0"
TEXT_SECOND   = "#8C94A6"
ACCENT        = "#5B9DFF"
AXIS_X        = "#EF5E5E"   # red
AXIS_Y        = "#67C46E"   # green
AXIS_Z        = "#559BE6"   # blue

SS = 4                       # supersampling factor
BASE = 1024                  # logical icon size (px)
CANVAS = BASE * SS


def hx(c: str, a: int = 255):
    c = c.lstrip("#")
    return (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16), a)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


# ---------------------------------------------------------------------------
# macOS "squircle" background (Big Sur superellipse), full-bleed on the canvas.
# ---------------------------------------------------------------------------
def squircle_mask(size: int, n: float = 5.0, inset_ratio: float = 0.0) -> Image.Image:
    """Superellipse mask filling the canvas (icon art bleeds to the rounded edge)."""
    mask = Image.new("L", (size, size), 0)
    px = mask.load()
    inset = size * inset_ratio
    cx = cy = size / 2.0
    r = (size / 2.0) - inset
    for y in range(size):
        ny = (y + 0.5 - cy) / r
        if abs(ny) > 1.0:
            continue
        # solve |nx|^n <= 1 - |ny|^n  =>  |nx| <= (1-|ny|^n)^(1/n)
        lim = (1.0 - abs(ny) ** n)
        if lim <= 0:
            continue
        nxlim = lim ** (1.0 / n)
        x0 = int(cx - nxlim * r)
        x1 = int(cx + nxlim * r)
        for x in range(max(0, x0), min(size, x1 + 1)):
            px[x, y] = 255
    return mask.filter(ImageFilter.GaussianBlur(size / 900.0))


def vertical_gradient(size, top, bottom):
    g = Image.new("RGB", (1, size))
    gp = g.load()
    for y in range(size):
        gp[0, y] = lerp(top, bottom, y / (size - 1))
    return g.resize((size, size))


def radial_gradient(size, inner, outer, cx=0.5, cy=0.42, radius=0.75):
    img = Image.new("RGB", (size, size))
    p = img.load()
    ccx, ccy, rr = cx * size, cy * size, radius * size
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - ccx, y - ccy) / rr
            p[x, y] = lerp(inner, outer, min(1.0, d))
    return img


# ---------------------------------------------------------------------------
# Isometric projection helpers
# ---------------------------------------------------------------------------
def iso(x, y, z, scale, ox, oy):
    """Standard 2:1 isometric projection. y is up."""
    a = math.radians(30)
    sx = (x - z) * math.cos(a)
    sy = (x + z) * math.sin(a) - y
    return (ox + sx * scale, oy + sy * scale)


# ===========================================================================
# VARIANT 1 — "The USDZ Cube": a solid isometric package with a bright top
# edge and an X/Y/Z axis gizmo rooted at the near corner. The .usdz-as-a-box.
# ===========================================================================
def draw_cube(d: ImageDraw.ImageDraw, size: int):
    ox, oy = size * 0.545, size * 0.55
    s = size * 0.205
    top    = [(-1, 1, -1), (1, 1, -1), (1, 1, 1), (-1, 1, 1)]
    left   = [(-1, 1, 1), (-1, -1, 1), (-1, -1, -1), (-1, 1, -1)]
    right  = [(-1, 1, 1), (1, 1, 1), (1, -1, 1), (-1, -1, 1)]

    def face(pts):
        return [iso(x, y, z, s, ox, oy) for (x, y, z) in pts]

    # Shaded faces: top brightest, right mid, left darkest — reads as a lit solid.
    d.polygon(face(left),  fill=hx(PANEL_BG))
    d.polygon(face(right), fill=hx(SURFACE_ELEV))
    d.polygon(face(top),   fill=hx(SURFACE_HOVER))

    # A subtle inner "content" cube floating inside — hint at an editable stage.
    inner = 0.5
    itop = [(-inner, inner, -inner), (inner, inner, -inner),
            (inner, inner, inner), (-inner, inner, inner)]
    d.polygon([iso(x, y, z, s, ox, oy) for (x, y, z) in itop],
              fill=None, outline=hx(ACCENT, 90), width=int(size * 0.006))

    # Bright accent edges along the top silhouette.
    ew = int(size * 0.011)
    top_pts = face(top)
    for i in range(len(top_pts)):
        d.line([top_pts[i], top_pts[(i + 1) % len(top_pts)]],
               fill=hx(ACCENT), width=ew)
    # Vertical near edge highlighted too.
    ne_a = iso(-1, 1, 1, s, ox, oy)
    ne_b = iso(-1, -1, 1, s, ox, oy)
    d.line([ne_a, ne_b], fill=hx(ACCENT, 140), width=ew)

    # Axis gizmo rooted at the top-near corner: X red, Y green, Z blue.
    root = iso(-1, 1, 1, s, ox, oy)
    g = 0.72
    axes = [((-1 - g, 1, 1), AXIS_X),       # -x direction (toward viewer-left)
            ((-1, 1 + g, 1), AXIS_Y),       # +y up
            ((-1, 1, 1 + g), AXIS_Z)]       # +z (toward viewer)
    aw = int(size * 0.014)
    for (pt, col) in axes:
        end = iso(pt[0], pt[1], pt[2], s, ox, oy)
        d.line([root, end], fill=hx(col), width=aw)
        rr = size * 0.018
        d.ellipse([end[0] - rr, end[1] - rr, end[0] + rr, end[1] + rr],
                  fill=hx(col))
    rr = size * 0.02
    d.ellipse([root[0] - rr, root[1] - rr, root[0] + rr, root[1] + rr],
              fill=hx(TEXT_PRIMARY))


def bg_cube(size):
    return vertical_gradient(size, hx(WINDOW_BG)[:3], hx(VIEWPORT_BG)[:3]).convert("RGBA")


# ===========================================================================
# VARIANT 2 — "Wireframe Prim": a glowing octahedron wireframe with lit
# vertices over a radial vignette. Speaks to mesh editing / prim topology.
# ===========================================================================
def draw_wireframe(d: ImageDraw.ImageDraw, size: int, glow_layer):
    ox, oy = size * 0.5, size * 0.5
    s = size * 0.30
    # Octahedron vertices.
    V = {
        "t": (0, 1.15, 0), "b": (0, -1.15, 0),
        "n": (0, 0, 1), "s": (0, 0, -1),
        "e": (1, 0, 0), "w": (-1, 0, 0),
    }
    P = {k: iso(*v, s, ox, oy) for k, v in V.items()}
    edges = [("t", "n"), ("t", "e"), ("t", "s"), ("t", "w"),
             ("b", "n"), ("b", "e"), ("b", "s"), ("b", "w"),
             ("n", "e"), ("e", "s"), ("s", "w"), ("w", "n")]

    # Faint filled facets for depth.
    for tri in [("t", "n", "e"), ("t", "e", "s"), ("b", "n", "e")]:
        d.polygon([P[k] for k in tri], fill=hx(ACCENT, 22))

    gw = int(size * 0.010)
    gd = ImageDraw.Draw(glow_layer)
    for a, b in edges:
        gd.line([P[a], P[b]], fill=hx(ACCENT, 200), width=int(size * 0.02))
        d.line([P[a], P[b]], fill=hx("#BFD8FF"), width=gw)

    # Lit vertices.
    for k, pt in P.items():
        rr = size * 0.024
        gd.ellipse([pt[0]-rr*2, pt[1]-rr*2, pt[0]+rr*2, pt[1]+rr*2], fill=hx(ACCENT, 160))
        d.ellipse([pt[0]-rr, pt[1]-rr, pt[0]+rr, pt[1]+rr], fill=hx(TEXT_PRIMARY))
    # Highlight one selected vertex in axis-Y green (edit-mode selection cue).
    sel = P["t"]
    rr = size * 0.03
    d.ellipse([sel[0]-rr, sel[1]-rr, sel[0]+rr, sel[1]+rr],
              fill=hx(AXIS_Y), outline=hx(TEXT_PRIMARY), width=int(size*0.006))


def bg_wire(size):
    return radial_gradient(size, hx(SURFACE_ELEV)[:3], hx(VIEWPORT_BG)[:3]).convert("RGBA")


# ===========================================================================
# VARIANT 3 — "Composed Stage": three stacked isometric layer-planes (USD
# composition / layer stack) with an accent prim resting on top. Minimal,
# flat, monoline — the "documenty" open-source feel.
# ===========================================================================
def draw_stage(d: ImageDraw.ImageDraw, size: int):
    ox = size * 0.5
    s = size * 0.30
    layers = [
        (size * 0.66, PANEL_BG,     PANEL_BORDER),
        (size * 0.57, SURFACE_ELEV, PANEL_BORDER),
        (size * 0.48, SURFACE_HOVER, ACCENT),
    ]
    ext = 1.0
    quad = [(-ext, 0, -ext), (ext, 0, -ext), (ext, 0, ext), (-ext, 0, ext)]
    bw = int(size * 0.007)
    for oy, fill, border in layers:
        pts = [iso(x, y, z, s, ox, oy) for (x, y, z) in quad]
        d.polygon(pts, fill=hx(fill), outline=hx(border), width=bw)

    # Accent "prim" — a small upright box sitting on the top plane.
    top_oy = layers[-1][0]
    bs = s * 0.42
    bx = ox
    by = top_oy - size * 0.02
    cube_top   = [(-1, 1, -1), (1, 1, -1), (1, 1, 1), (-1, 1, 1)]
    cube_left  = [(-1, 1, 1), (-1, 0, 1), (-1, 0, -1), (-1, 1, -1)]
    cube_right = [(-1, 1, 1), (1, 1, 1), (1, 0, 1), (-1, 0, 1)]
    def f(pts, oyy):
        return [iso(x, y, z, bs, bx, oyy) for (x, y, z) in pts]
    d.polygon(f(cube_left, by),  fill=lerp(hx(ACCENT), (13,15,19,255), 0.55))
    d.polygon(f(cube_right, by), fill=lerp(hx(ACCENT), (13,15,19,255), 0.30))
    d.polygon(f(cube_top, by),   fill=hx(ACCENT))

    # X/Y/Z corner ticks on the base plane — quiet nod to the gizmo.
    base_oy = layers[0][0]
    root = iso(-ext, 0, ext, s, ox, base_oy)
    for pt, col in [((-ext-0.5, 0, ext), AXIS_X),
                    ((-ext, 0, ext+0.5), AXIS_Z)]:
        end = iso(pt[0], pt[1], pt[2], s, ox, base_oy)
        d.line([root, end], fill=hx(col), width=int(size*0.012))


def bg_stage(size):
    return vertical_gradient(size, hx(PANEL_BG)[:3], hx(WINDOW_BG)[:3]).convert("RGBA")


# ---------------------------------------------------------------------------
# Variant registry + compositor
# ---------------------------------------------------------------------------
VARIANTS = {
    "cube":      ("The USDZ Cube",      bg_cube,  draw_cube,      False),
    "wireframe": ("Wireframe Prim",     bg_wire,  draw_wireframe, True),
    "stage":     ("Composed Stage",     bg_stage, draw_stage,     False),
}


def render(variant: str) -> Image.Image:
    _, bg_fn, draw_fn, needs_glow = VARIANTS[variant]
    size = CANVAS
    bg = bg_fn(size)

    art = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)
    if needs_glow:
        glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw_fn(d, size, glow)
        glow = glow.filter(ImageFilter.GaussianBlur(size * 0.02))
        bg = Image.alpha_composite(bg, glow)
    else:
        draw_fn(d, size)

    comp = Image.alpha_composite(bg, art)

    # Inner top sheen for a little glass depth.
    sheen = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.ellipse([-size*0.3, -size*0.55, size*1.3, size*0.35], fill=hx("#FFFFFF", 16))
    comp = Image.alpha_composite(comp, sheen)

    # Apply squircle mask + thin inner border ring.
    mask = squircle_mask(size, n=5.0)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(comp, (0, 0), mask)

    ring = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    # emulate a hairline border by masking a slightly inset squircle difference
    inner = squircle_mask(size, n=5.0, inset_ratio=0.012)
    border = Image.new("RGBA", (size, size), hx(PANEL_BORDER, 160))
    ring.paste(border, (0, 0), mask)
    ring.paste((0, 0, 0, 0), (0, 0), inner)
    out = Image.alpha_composite(out, ring)

    return out.resize((BASE, BASE), Image.LANCZOS)


# ---------------------------------------------------------------------------
# Packaging: .appiconset (macOS) + .icns
# ---------------------------------------------------------------------------
MAC_SIZES = [16, 32, 64, 128, 256, 512, 1024]  # includes @2x via naming below


def write_appiconset(master: Image.Image, dest: Path):
    dest.mkdir(parents=True, exist_ok=True)
    entries = []
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for pt, scale in specs:
        px = pt * scale
        fn = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(dest / fn)
        entries.append(
            '    {\n'
            f'      "size" : "{pt}x{pt}",\n'
            '      "idiom" : "mac",\n'
            f'      "filename" : "{fn}",\n'
            f'      "scale" : "{scale}x"\n'
            '    }'
        )
    contents = '{\n  "images" : [\n' + ",\n".join(entries) + \
               '\n  ],\n  "info" : {\n    "version" : 1,\n    "author" : "openusdz-icon-script"\n  }\n}\n'
    (dest / "Contents.json").write_text(contents)


def write_icns(master: Image.Image, dest_icns: Path, workdir: Path):
    iconset = workdir / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    plan = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
            (256, 1), (256, 2), (512, 1), (512, 2)]
    for pt, scale in plan:
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(iconset / name)
    try:
        subprocess.run(["iconutil", "-c", "icns", str(iconset),
                        "-o", str(dest_icns)], check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"  (iconutil unavailable, skipped .icns: {e})")
        return False
    finally:
        shutil.rmtree(iconset, ignore_errors=True)  # drop intermediate staging dir


def main():
    ap = argparse.ArgumentParser(description="Generate OpenUSDZEditor app icons (pure CLI).")
    ap.add_argument("--variant", choices=list(VARIANTS), help="render just one variant preview")
    ap.add_argument("--pick", choices=list(VARIANTS),
                    help="chosen variant -> also emit AppIcon.appiconset + .icns")
    ap.add_argument("--out", default="Resources/AppIcon", help="output directory")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[2]
    out = (root / args.out)
    preview = out / "previews"
    preview.mkdir(parents=True, exist_ok=True)

    to_render = [args.variant] if args.variant else list(VARIANTS)
    masters = {}
    for v in to_render:
        print(f"rendering variant: {v} ({VARIANTS[v][0]})")
        img = render(v)
        masters[v] = img
        img.save(preview / f"{v}_1024.png")
        # small contact-sheet-friendly 256 too
        img.resize((256, 256), Image.LANCZOS).save(preview / f"{v}_256.png")
    print(f"previews -> {preview}")

    if args.pick:
        master = masters.get(args.pick) or render(args.pick)
        write_appiconset(master, out / "AppIcon.appiconset")
        write_icns(master, out / "AppIcon.icns", out)
        print(f"picked '{args.pick}' -> {out/'AppIcon.appiconset'} + {out/'AppIcon.icns'}")


if __name__ == "__main__":
    main()
