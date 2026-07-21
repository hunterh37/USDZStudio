#!/usr/bin/env python3
"""Author a textured UV-sphere USD asset (correct st/normals + UsdUVTexture ->
UsdPreviewSurface albedo) and package it as a self-contained .usdz.

Runs headless with the bundled usd-core Python (needs `pxr`):

    Resources/Python/runtime/bin/python3 build_textured_sphere.py \
        --texture /abs/earth.jpg --out /abs/earth.usdz [--radius 1 --stacks 96 --slices 192]

Notes learned the hard way (see promo-image SKILL.md):
- Import the RESULT via `import_asset` on the .usdz/.usda path — that preserves
  point3f[]/texCoord2f[] types. glTF/GLB/OBJ imports get flattened to double[]
  points (vertices=0, unrenderable).
- Package the UN-flattened layer with CWD = the texture dir so the bare-filename
  asset ref resolves and gets gathered (flattening first anchors it to `0/...`).
"""
import argparse
import math
import os


def uv_sphere(radius, stacks, slices):
    from pxr import Gf, Vt
    pts, nrm, sts, counts, idx = [], [], [], [], []
    row = slices + 1
    for i in range(stacks + 1):
        th = math.pi * i / stacks
        y, r = math.cos(th), math.sin(th)
        for j in range(slices + 1):
            ph = 2 * math.pi * j / slices
            x, z = r * math.cos(ph), r * math.sin(ph)
            pts.append(Gf.Vec3f(radius * x, radius * y, radius * z))
            nrm.append(Gf.Vec3f(x, y, z))
            sts.append(Gf.Vec2f(j / slices, 1.0 - i / stacks))
    for i in range(stacks):
        for j in range(slices):
            a = i * row + j
            b, c, d = a + 1, a + row, a + row + 1
            if i != 0:
                counts.append(3); idx += [a, c, b]
            if i != stacks - 1:
                counts.append(3); idx += [b, c, d]
    return (Vt.Vec3fArray(pts), Vt.Vec3fArray(nrm), Vt.Vec2fArray(sts),
            Vt.IntArray(counts), Vt.IntArray(idx))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--texture", required=True, help="equirectangular albedo (abs path)")
    ap.add_argument("--out", required=True, help="output .usdz (abs path)")
    ap.add_argument("--radius", type=float, default=1.0)
    ap.add_argument("--stacks", type=int, default=96)
    ap.add_argument("--slices", type=int, default=192)
    args = ap.parse_args()

    from pxr import Usd, UsdGeom, UsdShade, Sdf, Vt, Gf, UsdUtils

    tex_dir = os.path.dirname(os.path.abspath(args.texture))
    tex_name = os.path.basename(args.texture)
    usda = os.path.join(tex_dir, "_textured_sphere.usda")
    out = os.path.abspath(args.out)

    stage = Usd.Stage.CreateNew(usda)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    root = UsdGeom.Xform.Define(stage, "/Object")
    stage.SetDefaultPrim(root.GetPrim())

    pts, nrm, sts, counts, idx = uv_sphere(args.radius, args.stacks, args.slices)
    m = UsdGeom.Mesh.Define(stage, "/Object/Surface")
    m.CreatePointsAttr(pts)
    m.CreateFaceVertexCountsAttr(counts)
    m.CreateFaceVertexIndicesAttr(idx)
    m.CreateNormalsAttr(nrm)
    m.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
    m.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    e = args.radius * 1.001
    m.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(-e, -e, -e), Gf.Vec3f(e, e, e)]))
    UsdGeom.PrimvarsAPI(m).CreatePrimvar(
        "st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex).Set(sts)

    mat = UsdShade.Material.Define(stage, "/Object/Mat")
    rdr = UsdShade.Shader.Define(stage, "/Object/Mat/stReader")
    rdr.CreateIdAttr("UsdPrimvarReader_float2")
    rdr.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("st")
    rdr.CreateOutput("result", Sdf.ValueTypeNames.Float2)
    surf = UsdShade.Shader.Define(stage, "/Object/Mat/Surface")
    surf.CreateIdAttr("UsdPreviewSurface")
    surf.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
    surf.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.6)
    tex = UsdShade.Shader.Define(stage, "/Object/Mat/albedo")
    tex.CreateIdAttr("UsdUVTexture")
    tex.CreateInput("file", Sdf.ValueTypeNames.Asset).Set(tex_name)  # bare name
    tex.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(
        rdr.ConnectableAPI(), "result")
    tex.CreateInput("wrapS", Sdf.ValueTypeNames.Token).Set("repeat")
    tex.CreateInput("wrapT", Sdf.ValueTypeNames.Token).Set("clamp")
    tex.CreateOutput("rgb", Sdf.ValueTypeNames.Float3)
    surf.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(
        tex.ConnectableAPI(), "rgb")
    mat.CreateSurfaceOutput().ConnectToSource(surf.ConnectableAPI(), "surface")
    UsdShade.MaterialBindingAPI(m).Bind(mat)
    stage.GetRootLayer().Save()

    os.chdir(tex_dir)                       # so bare texture ref resolves
    if os.path.exists(out):
        os.remove(out)
    UsdUtils.CreateNewUsdzPackage(os.path.basename(usda), out)
    os.remove(usda)
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
