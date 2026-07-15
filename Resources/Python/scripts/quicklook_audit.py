"""QuickLook Audit — will this asset behave well in AR Quick Look?

A fast pre-flight against the constraints that make USDZ assets misbehave on
iOS/visionOS AR Quick Look and in RealityKit (PRD §2 AR/spatial developers,
§4 conversion targets). Complements ValidationKit's rule engine with a
scriptable, CI-runnable summary.

Checks:
  * total triangle count vs a budget (default 100k)
  * texture longest-edge vs 2048 and power-of-two-ness
  * a single defaultPrim is authored (AR Quick Look loads it)
  * stage metersPerUnit / upAxis are set (silent scale/orientation bugs)
  * unresolvable (missing) texture assets

Read-only. Human summary, or --json with a pass/warn/fail verdict and exit
codes 0 ok / 1 warnings / 2 errors (matches the CLI contract in
specs/scripting.md).
"""

import json
import os
import sys

from _harness import begin, finish

MANIFEST = {
    "name": "QuickLook Audit",
    "description": "Pre-flight an asset against AR Quick Look constraints.",
    "mutates": False,
    "args": [
        {"name": "json", "type": "bool", "default": False,
         "help": "Emit JSON with a verdict instead of text."},
        {"name": "tri_budget", "type": "int", "default": 100000,
         "help": "Triangle-count budget before warning."},
        {"name": "tex_max", "type": "int", "default": 2048,
         "help": "Max texture longest-edge before warning."},
    ],
}


def _triangle_count(stage):
    from pxr import UsdGeom
    tris = 0
    for prim in stage.Traverse():
        mesh = UsdGeom.Mesh(prim)
        if not mesh:
            continue
        counts = mesh.GetFaceVertexCountsAttr().Get()
        if not counts:
            continue
        # A face with n verts triangulates to (n - 2) triangles.
        tris += sum(max(0, c - 2) for c in counts)
    return tris


def _is_pow2(n):
    return n > 0 and (n & (n - 1)) == 0


def _texture_findings(stage, tex_max):
    from pxr import UsdShade, Sdf
    findings = []
    for prim in stage.Traverse():
        shader = UsdShade.Shader(prim)
        if not shader:
            continue
        for inp in shader.GetInputs():
            if inp.GetTypeName() != Sdf.ValueTypeNames.Asset:
                continue
            asset = inp.Get()
            if asset is None:
                continue
            resolved = asset.resolvedPath or ""
            if not resolved or not os.path.exists(resolved):
                findings.append(("error", "missing texture: %s" % asset.path))
                continue
            try:
                from PIL import Image
                with Image.open(resolved) as im:
                    w, h = im.size
                if max(w, h) > tex_max:
                    findings.append(("warn", "texture %dx%d exceeds %d: %s"
                                     % (w, h, tex_max, os.path.basename(resolved))))
                if not (_is_pow2(w) and _is_pow2(h)):
                    findings.append(("warn", "non-power-of-two texture: %s"
                                     % os.path.basename(resolved)))
            except Exception:
                pass  # dimensions unavailable without Pillow; skip silently
    return findings


def main():
    from pxr import UsdGeom
    ctx = begin(globals(), MANIFEST)
    stage = ctx.stage
    findings = []

    tris = _triangle_count(stage)
    if tris > (ctx.args.tri_budget or 100000):
        findings.append(("warn", "%d triangles exceeds budget %d"
                         % (tris, ctx.args.tri_budget)))

    if not stage.GetDefaultPrim():
        findings.append(("error", "no defaultPrim — AR Quick Look may load "
                                   "nothing or the wrong prim"))

    if not stage.HasAuthoredMetadata(UsdGeom.Tokens.metersPerUnit):
        findings.append(("warn", "metersPerUnit not authored — scale is a guess"))
    if not stage.HasAuthoredMetadata(UsdGeom.Tokens.upAxis):
        findings.append(("warn", "upAxis not authored — orientation is a guess"))

    findings += _texture_findings(stage, ctx.args.tex_max or 2048)

    errors = [m for lvl, m in findings if lvl == "error"]
    warns = [m for lvl, m in findings if lvl == "warn"]
    verdict = "fail" if errors else ("warn" if warns else "pass")

    if getattr(ctx.args, "json", False):
        json.dump({"verdict": verdict, "triangles": tris,
                   "errors": errors, "warnings": warns}, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print("QuickLook audit: %s" % verdict.upper())
        print("  triangles: %d" % tris)
        for lvl, msg in findings:
            print("  [%s] %s" % (lvl, msg))
        if verdict == "pass":
            print("  no issues found")

    finish(ctx)
    if not ctx.injected:
        sys.exit(2 if errors else (1 if warns else 0))


if __name__ == "__main__" or globals().get("stage") is not None:
    main()
