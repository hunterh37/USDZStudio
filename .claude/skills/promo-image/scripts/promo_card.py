#!/usr/bin/env python3
"""Branded before/after split card for OpenUSDZEditor promos.

House style: dark vertical-gradient bg, one blue accent (#5696FF), two rounded
square panels (BEFORE muted border / AFTER accent border), a circular arrow
badge between them, kicker + headline + subhead, panel captions, footer.
See the promo-image SKILL.md.

    python3 promo_card.py --before before.png --after after.png --out promo.png \
        --title "Texture anything. Natively." --subtitle "..."
"""
import argparse

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def font(size):
    for p in ("/System/Library/Fonts/SFNS.ttf",
              "/System/Library/Fonts/Helvetica.ttc",
              "/Library/Fonts/Arial.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()


def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def vgrad(w, h, top, bot):
    t = np.linspace(0, 1, h)[:, None, None]
    arr = np.array(top)[None, None] * (1 - t) + np.array(bot)[None, None] * t
    return Image.fromarray(np.tile(arr, (1, w, 1)).astype(np.uint8))


def fit_square(path, size):
    im = Image.open(path).convert("RGB")
    s = min(im.size)
    im = im.crop(((im.width - s) // 2, (im.height - s) // 2,
                  (im.width + s) // 2, (im.height + s) // 2))
    return im.resize((size, size), Image.LANCZOS)


def rounded(img, radius, border):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, img.width - 1, img.height - 1], radius, fill=255)
    out = Image.new("RGB", img.size, (0, 0, 0))
    out.paste(img, (0, 0), mask)
    ImageDraw.Draw(out).rounded_rectangle(
        [0, 0, img.width - 1, img.height - 1], radius, outline=border, width=3)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--kicker", default="OPENUSDZ  EDITOR")
    ap.add_argument("--title", default="Texture anything. Natively.")
    ap.add_argument("--subtitle", default="Import a reference photo and wrap real "
                    "geometry with a full PBR material — right in the editor.")
    ap.add_argument("--before-label", default="BEFORE")
    ap.add_argument("--after-label", default="AFTER")
    ap.add_argument("--before-caption", default="Untextured primitive")
    ap.add_argument("--after-caption", default="Photoreal, textured render")
    ap.add_argument("--footer-left",
                    default="Open source · SwiftUI + RealityKit + OpenUSD · macOS")
    ap.add_argument("--footer-right", default="Star us on GitHub  ★")
    ap.add_argument("--accent", default="#5696FF")
    args = ap.parse_args()

    W, H, PANEL, PAD = 2400, 1500, 980, 90
    accent = hex_rgb(args.accent)
    canvas = vgrad(W, H, (13, 15, 22), (6, 7, 11)).convert("RGB")
    d = ImageDraw.Draw(canvas)

    d.text((PAD, 70), args.kicker, font=font(34), fill=accent)
    d.text((PAD, 118), args.title, font=font(82), fill=(240, 244, 252))
    d.text((PAD, 224), args.subtitle, font=font(38), fill=(150, 162, 182))

    py, lx, rx = 330, PAD, W - PAD - PANEL
    canvas.paste(rounded(fit_square(args.before, PANEL), 28, (54, 60, 76)), (lx, py))
    canvas.paste(rounded(fit_square(args.after, PANEL), 28, accent), (rx, py))

    f_lab, f_cap = font(40), font(30)
    d.text((lx + 6, py + PANEL + 22), args.before_label, font=f_lab, fill=(150, 158, 174))
    d.text((lx + 6, py + PANEL + 72), args.before_caption, font=f_cap, fill=(110, 118, 134))
    d.text((rx + 6, py + PANEL + 22), args.after_label, font=f_lab, fill=accent)
    d.text((rx + 6, py + PANEL + 72), args.after_caption, font=f_cap, fill=(150, 162, 182))

    cx, cy, r = W // 2, py + PANEL // 2, 66
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=accent)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255), width=4)
    af = font(70)
    tb = d.textbbox((0, 0), "→", font=af)
    d.text((cx - (tb[2] - tb[0]) / 2 - tb[0], cy - (tb[3] - tb[1]) / 2 - tb[1]),
           "→", font=af, fill=(255, 255, 255))

    ff = font(30)
    d.text((PAD, H - 66), args.footer_left, font=ff, fill=(120, 130, 148))
    tb = d.textbbox((0, 0), args.footer_right, font=ff)
    d.text((W - PAD - (tb[2] - tb[0]), H - 66), args.footer_right, font=ff, fill=(150, 162, 182))

    canvas.save(args.out)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
