#!/usr/bin/env python3
"""Convert an authored .usda layer to .usdc or package it as .usdz.

Usage: python3 stage_save.py /tmp/in.usda /path/out.usdz
The Swift side (USDBridge.StageSaver) authors the .usda text itself; this
script only performs the format conversion USD's C++ core must do.
"""
import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: stage_save.py <in.usda> <out.usdc|out.usdz>\n")
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    try:
        from pxr import Usd, UsdUtils
    except ImportError as exc:
        sys.stderr.write("usd-core not importable: %s\n" % exc)
        return 3

    stage = Usd.Stage.Open(src)
    if stage is None:
        sys.stderr.write("could not open authored layer: %s\n" % src)
        return 4

    if dst.endswith(".usdz"):
        if not UsdUtils.CreateNewUsdzPackage(src, dst):
            sys.stderr.write("usdz packaging failed for %s\n" % dst)
            return 5
    else:
        if not stage.Export(dst):
            sys.stderr.write("export failed for %s\n" % dst)
            return 5
    return 0


if __name__ == "__main__":
    sys.exit(main())
