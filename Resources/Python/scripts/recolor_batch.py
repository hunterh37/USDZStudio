"""Recolor Batch — perceptually recolor solid-color materials toward a target.

The e-commerce "rebrand 200 SKUs" workflow (specs/recoloring.md §Scripting &
Batch): remap every UsdPreviewSurface's ``diffuseColor`` toward one target hue
while preserving each material's own lightness, so a catalog of parts shifts to
the new brand color without going flat. The remap runs in OKLab — the same
perceptual space as the Swift ``RecolorEngine`` — so hue/chroma move
perceptually while lightness (the shading/contrast) is preserved.

Textured parts (albedo fed by a ``UsdUVTexture``) are reported and skipped:
recoloring texture *bytes* is the app's live GPU/CPU path, not a stage edit
(and in-stage texture-network authoring is ROADMAP Phase 7).

Mutating. Operates on the selection if any, else the whole stage.
"""

import math

from _harness import begin, finish

MANIFEST = {
    "name": "Recolor Batch",
    "description": "Perceptually recolor solid-color materials toward a target hue.",
    "mutates": True,
    "args": [
        {"name": "color", "type": "str", "default": "#FF6B00",
         "help": "Target color as #RRGGBB (sRGB)."},
        {"name": "chroma_preservation", "type": "float", "default": 1.0,
         "help": "0 = flatten chroma to target, 1 = keep per-material spread."},
        {"name": "lightness_bias", "type": "float", "default": 0.0,
         "help": "Added to each material's OKLab lightness (light<->dark)."},
    ],
}


# --- Color management (OKLab), mirroring ConversionKit/ColorManagement.swift ---

def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _hex_to_linear(text):
    """'#RRGGBB' (sRGB) -> linear RGB triple, or None if malformed."""
    h = text[1:] if text.startswith("#") else text
    if len(h) != 6:
        return None
    try:
        r = int(h[0:2], 16) / 255.0
        g = int(h[2:4], 16) / 255.0
        b = int(h[4:6], 16) / 255.0
    except ValueError:
        return None
    return (_srgb_to_linear(r), _srgb_to_linear(g), _srgb_to_linear(b))


def _linear_to_oklab(c):
    r, g, b = c
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = _cbrt(l), _cbrt(m), _cbrt(s)
    return (
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    )


def _oklab_to_linear(lab):
    L, a, b = lab
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    return (
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    )


def _cbrt(x):
    return math.copysign(abs(x) ** (1.0 / 3.0), x)


def _to_lch(lab):
    L, a, b = lab
    return (L, math.hypot(a, b), math.atan2(b, a))


def _from_lch(lch):
    L, C, h = lch
    return (L, C * math.cos(h), C * math.sin(h))


def _remap(linear, target_lch, chroma_preservation, lightness_bias):
    """Move a linear color toward the target hue/chroma, keeping its lightness."""
    L, C, _h = _to_lch(_linear_to_oklab(linear))
    new_C = max(0.0, target_lch[1] + (C - target_lch[1]) * chroma_preservation)
    new_L = max(0.0, min(1.0, L + lightness_bias))
    return _oklab_to_linear(_from_lch((new_L, new_C, target_lch[2])))


# --- Shader traversal ---

def _diffuse_inputs(stage, prims):
    """Yield (shader, diffuseColor input) for every PreviewSurface, plus a flag
    for whether the diffuse is texture-driven (connected), which we skip."""
    from pxr import UsdShade
    for prim in prims:
        shader = UsdShade.Shader(prim)
        if not shader:
            continue
        shader_id = shader.GetShaderId() if hasattr(shader, "GetShaderId") else None
        if shader_id not in (None, "UsdPreviewSurface"):
            continue
        diffuse = shader.GetInput("diffuseColor")
        if not diffuse:
            continue
        textured = bool(diffuse.GetConnectedSources()[0]) if diffuse.HasConnectedSource() else False
        yield shader, diffuse, textured


def main():
    ctx = begin(globals(), MANIFEST)
    target_linear = _hex_to_linear(ctx.args.color)
    if target_linear is None:
        ctx.app.log("error: --color must be #RRGGBB, got %r" % ctx.args.color)
        return
    target_lch = _to_lch(_linear_to_oklab(target_linear))

    recolored, skipped_textured = 0, 0
    for _shader, diffuse, textured in _diffuse_inputs(ctx.stage, ctx.prims()):
        if textured:
            skipped_textured += 1
            continue
        value = diffuse.Get()
        if value is None:
            continue
        new = _remap(tuple(value), target_lch,
                     ctx.args.chroma_preservation, ctx.args.lightness_bias)
        if not ctx.dry_run:
            diffuse.Set(type(value)(*new))
        recolored += 1

    summary = "recolored %d material(s) toward %s" % (recolored, ctx.args.color)
    if skipped_textured:
        summary += "; skipped %d textured (use the app's live recolor)" % skipped_textured
    ctx.app.log(summary)
    finish(ctx)


if __name__ == "__main__":
    main()
