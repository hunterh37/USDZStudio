"""Flatten and Export — collapse composition into one self-contained file.

Resolves all references, payloads, sublayers, variants and over-opinions into
a single flattened layer, then writes it out. Useful for shipping a clean
deliverable, debugging composition, or producing a packaged .usdz whose
textures travel inside the archive.

Behaviour by output extension:
  .usdz  -> flatten, then package (textures embedded)
  .usdc  -> flattened binary crate
  .usda  -> flattened ASCII (handy for diffing / inspection)

This is a read-only operation on the source stage: it never modifies the
input, it only writes `--output`. `--output` is required.
"""

import os
import sys

from _harness import begin

MANIFEST = {
    "name": "Flatten and Export",
    "description": "Collapse composition and export a self-contained file.",
    "mutates": False,   # source stage is untouched; we manage our own write
    "args": [
        {"name": "output", "type": "str", "default": None,
         "help": "Destination .usdz/.usdc/.usda (required)."},
    ],
}


def main():
    from pxr import UsdUtils
    ctx = begin(globals(), MANIFEST)
    out = ctx.args.output
    if not out:
        raise ValueError("--output is required (e.g. --output flat.usdz)")

    ext = os.path.splitext(out)[1].lower()
    if ext not in (".usdz", ".usdc", ".usda"):
        raise ValueError("output must end in .usdz, .usdc or .usda")

    flat = ctx.stage.Flatten()

    if ext == ".usdz":
        tmp = out + ".flat.usdc"
        flat.Export(tmp)
        try:
            if not UsdUtils.CreateNewUsdzPackage(tmp, out):
                raise RuntimeError("failed to create usdz package: %s" % out)
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
    else:
        flat.Export(out)

    ctx.app.log("exported", out)
    # No finish(): this script owns its own write and leaves the stage clean.


if __name__ == "__main__" or globals().get("stage") is not None:
    main()
