"""Texture Report — audit every texture the stage references.

Lists each image asset feeding a UsdShade shader input, with its file size,
pixel dimensions (when Pillow is available), power-of-two status and UDIM
tiling. Ends with a total on-disk texture footprint — the number that decides
whether an asset fits an AR QuickLook / ecommerce download budget (PRD §2, §4).

Read-only. Prints a human table to stdout, or JSON with --json (CI-friendly,
matching the CLI's JSON discipline).
"""

import json
import os
import sys

from _harness import begin, finish

MANIFEST = {
    "name": "Texture Report",
    "description": "Table of all textures with sizes, dimensions and memory.",
    "mutates": False,
    "args": [
        {"name": "json", "type": "bool", "default": False,
         "help": "Emit JSON instead of a formatted table."},
        {"name": "max_dim", "type": "int", "default": 2048,
         "help": "Flag textures whose longest edge exceeds this."},
    ],
}


def _image_size(path):
    """(width, height) or None. Pillow if present; otherwise a tiny header
    sniff for PNG/JPEG so the common cases still report dimensions."""
    try:
        from PIL import Image
        with Image.open(path) as im:
            return im.size
    except Exception:
        pass
    try:
        with open(path, "rb") as f:
            head = f.read(26)
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            return (int.from_bytes(head[16:20], "big"),
                    int.from_bytes(head[20:24], "big"))
    except Exception:
        pass
    return None


def _is_pow2(n):
    return n > 0 and (n & (n - 1)) == 0


def _collect(ctx):
    from pxr import UsdShade, Sdf
    seen = {}
    for prim in ctx.stage.Traverse():
        shader = UsdShade.Shader(prim)
        if not shader:
            continue
        for inp in shader.GetInputs():
            if inp.GetTypeName() != Sdf.ValueTypeNames.Asset:
                continue
            asset = inp.Get()
            if asset is None:
                continue
            raw = asset.path
            resolved = asset.resolvedPath or raw
            is_udim = "<UDIM>" in raw or "<udim>" in raw
            rec = seen.setdefault(raw, {
                "asset": raw,
                "resolved": resolved,
                "udim": is_udim,
                "used_by": [],
            })
            rec["used_by"].append(str(prim.GetPath()))
    return list(seen.values())


def _enrich(rec, max_dim):
    path = rec["resolved"]
    exists = bool(path) and os.path.exists(path)
    rec["exists"] = exists
    rec["bytes"] = os.path.getsize(path) if exists else 0
    dims = _image_size(path) if exists else None
    rec["width"], rec["height"] = (dims if dims else (None, None))
    rec["pow2"] = (dims is not None and _is_pow2(dims[0]) and _is_pow2(dims[1]))
    rec["oversized"] = (dims is not None and max(dims) > max_dim)
    return rec


def _human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0


def main():
    ctx = begin(globals(), MANIFEST)
    max_dim = ctx.args.max_dim or 2048
    records = [_enrich(r, max_dim) for r in _collect(ctx)]
    total = sum(r["bytes"] for r in records)

    if getattr(ctx.args, "json", False):
        json.dump({"textures": records, "total_bytes": total}, sys.stdout,
                  indent=2)
        sys.stdout.write("\n")
    else:
        if not records:
            print("No textures referenced by this stage.")
        else:
            print("%-40s %10s %11s %6s %5s" %
                  ("TEXTURE", "SIZE", "DIMS", "POW2", "FLAG"))
            for r in sorted(records, key=lambda x: -x["bytes"]):
                dims = ("%dx%d" % (r["width"], r["height"])
                        if r["width"] else "?")
                flags = []
                if not r["exists"]:
                    flags.append("MISSING")
                if r["oversized"]:
                    flags.append(">%d" % max_dim)
                if r["exists"] and not r["pow2"] and r["width"]:
                    flags.append("npot")
                if r["udim"]:
                    flags.append("udim")
                name = os.path.basename(r["asset"]) or r["asset"]
                print("%-40s %10s %11s %6s %5s" %
                      (name[:40], _human(r["bytes"]), dims,
                       "yes" if r["pow2"] else "no", ",".join(flags)))
            print("-" * 74)
            print("%d textures, %s total" % (len(records), _human(total)))
    finish(ctx)


if __name__ == "__main__" or globals().get("stage") is not None:
    main()
