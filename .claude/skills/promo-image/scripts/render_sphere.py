#!/usr/bin/env python3
"""Photoreal orthographic sphere/globe render from an equirectangular texture.

House style for OpenUSDZEditor promos: linear-light shading, wrap-Lambert
terminator, blue atmosphere limb + outer glow ring, 2x supersample. See the
promo-image SKILL.md for the full aesthetic contract.

    python3 render_sphere.py --texture earth.jpg --out after.png [options]
"""
import argparse

import numpy as np
from PIL import Image


def load(path, size=None, mode="RGB"):
    im = Image.open(path).convert(mode)
    if size:
        im = im.resize(size, Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def sample_equirect(tex, lon, lat):
    """Bilinear equirectangular sample. tex is HxWxC; lon/lat in radians."""
    h, w = tex.shape[:2]
    u = (lon / (2 * np.pi) + 0.5) % 1.0
    v = np.clip(0.5 - lat / np.pi, 0, 1)
    fx = u * w - 0.5
    fy = v * (h - 1)
    x0 = np.floor(fx).astype(int)
    y0 = np.clip(np.floor(fy).astype(int), 0, h - 1)
    x1 = (x0 + 1) % w
    y1 = np.clip(y0 + 1, 0, h - 1)
    tx = (fx - x0)[..., None]
    ty = (fy - y0)[..., None]
    x0 %= w
    top = tex[y0, x0] * (1 - tx) + tex[y0, x1] * tx
    bot = tex[y1, x0] * (1 - tx) + tex[y1, x1] * tx
    return top * (1 - ty) + bot * ty


def parse_vec(s, n, default):
    if not s:
        return np.array(default, dtype=float)
    parts = [float(x) for x in s.replace(" ", "").split(",")]
    assert len(parts) == n, "expected %d comma-separated values, got %r" % (n, s)
    return np.array(parts, dtype=float)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--texture", required=True, help="equirectangular albedo image")
    ap.add_argument("--out", required=True, help="output PNG")
    ap.add_argument("--size", type=int, default=1600, help="output edge px (default 1600)")
    ap.add_argument("--ss", type=int, default=2, help="supersample factor (default 2)")
    ap.add_argument("--fill", type=float, default=0.86,
                    help="fraction of frame the disc fills (default 0.86)")
    ap.add_argument("--tilt", type=float, default=23.4, help="axial tilt degrees")
    ap.add_argument("--center-lon", type=float, default=-30.0,
                    help="longitude (deg) facing the viewer/light")
    ap.add_argument("--light", default="-0.6,0.45,0.65", help="light dir x,y,z")
    ap.add_argument("--bg", default="8,9,14", help="space background r,g,b (0-255)")
    ap.add_argument("--atmo", default="0.30,0.55,1.0", help="atmosphere color r,g,b (0-1)")
    ap.add_argument("--night", type=float, default=0.08, help="night-side ambient (default 0.08)")
    ap.add_argument("--spec", type=float, default=0.0,
                    help="ocean/whole-sphere specular strength (default 0 = off)")
    args = ap.parse_args()

    tilt = np.deg2rad(args.tilt)
    lon0 = np.deg2rad(args.center_lon)
    light = parse_vec(args.light, 3, [-0.6, 0.45, 0.65])
    light = light / np.linalg.norm(light)
    bg = parse_vec(args.bg, 3, [8, 9, 14]) / 255.0
    atmo_col = parse_vec(args.atmo, 3, [0.30, 0.55, 1.0])

    res = args.size * args.ss
    albedo = srgb_to_lin(load(args.texture))

    lin = (np.arange(res) + 0.5) / res * 2 - 1
    sx, sy = np.meshgrid(lin, -lin)
    r = 1.0 / args.fill
    px, py = sx * r, sy * r
    rho2 = px * px + py * py
    disc = rho2 <= 1.0

    pz = np.zeros_like(px)
    pz[disc] = np.sqrt(1.0 - rho2[disc])
    nx, ny, nz = px, py, pz          # view-space normal on unit sphere

    # Undo axial tilt (rotate about screen X) to reach the geographic frame.
    ct, st = np.cos(-tilt), np.sin(-tilt)
    gy = ny * ct - nz * st
    gz = ny * st + nz * ct
    gx = nx
    lat = np.arcsin(np.clip(gy, -1, 1))
    lon = np.arctan2(gx, gz) + lon0

    alb = np.zeros((res, res, 3), dtype=np.float32)
    alb[disc] = sample_equirect(albedo, lon[disc], lat[disc])

    ndl = nx * light[0] + ny * light[1] + nz * light[2]
    wrap = np.clip((ndl + 0.18) / 1.18, 0, 1)
    diffuse = wrap ** 1.1
    col = alb * (args.night + (1 - args.night) * diffuse[..., None])

    if args.spec > 0:
        view = np.array([0, 0, 1.0])
        hvec = light + view
        hvec /= np.linalg.norm(hvec)
        ndh = np.clip(nx * hvec[0] + ny * hvec[1] + nz * hvec[2], 0, 1)
        spec = (ndh ** 220) * np.clip(ndl, 0, 1)
        col += spec[..., None] * np.array([1.0, 0.97, 0.9]) * args.spec

    out = lin_to_srgb(col)

    # Atmosphere: inner limb haze (lit side) + outer glow ring beyond the disc.
    rho = np.sqrt(rho2)
    limb = np.clip((rho - 0.75) / 0.25, 0, 1) ** 2 * disc
    daymask = np.clip(ndl + 0.3, 0, 1)
    out = out + (limb * daymask)[..., None] * atmo_col * 0.6

    glow = np.exp(-np.clip(rho - 1.0, 0, None) * 14.0) * (~disc)
    litside = np.clip(sx * light[0] + sy * light[1] + 0.5, 0, 1)
    bgimg = bg[None, None, :] + glow[..., None] * atmo_col * 0.9 * litside[..., None]

    frame = np.clip(np.where(disc[..., None], out, bgimg), 0, 1)
    img = Image.fromarray((frame * 255).astype(np.uint8))
    if args.ss != 1:
        img = img.resize((args.size, args.size), Image.LANCZOS)
    img.save(args.out)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
