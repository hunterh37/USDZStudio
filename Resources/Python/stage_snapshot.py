#!/usr/bin/env python3
"""Emit a JSON prim-tree snapshot of a USD file to stdout.

Wire format decoded by USDBridge.StageSnapshotDecoder — keep the two in sync.
Usage: python3 stage_snapshot.py /path/to/file.usdz
"""
import json
import sys


def attribute_payload(attr):
    """Map a Usd.Attribute to the closed wire type set; exotic types are
    preserved by name as unsupported (never silently dropped)."""
    type_name = str(attr.GetTypeName())
    value = attr.Get()
    out = {"name": attr.GetName(), "type": "unsupported:" + type_name}
    if value is None:
        return out
    try:
        if type_name == "bool":
            out.update(type="bool", bool=bool(value))
        elif type_name in ("int", "uint", "int64"):
            out.update(type="int", int=int(value))
        elif type_name in ("float", "double", "half"):
            out.update(type="double", double=float(value))
        elif type_name == "string":
            out.update(type="string", string=str(value))
        elif type_name == "token":
            out.update(type="token", string=str(value))
        elif type_name == "asset":
            out.update(type="asset", string=str(value.path))
        elif type_name in ("float2", "double2", "float3", "double3", "color3f",
                           "normal3f", "point3f", "vector3f", "float4", "double4",
                           "quatf", "quatd", "texCoord2f"):
            out.update(type="vector", doubles=[float(c) for c in value])
        elif type_name == "matrix4d":
            out.update(type="matrix4d",
                       doubles=[float(c) for row in value for c in row])
        elif type_name in ("int[]", "uint[]"):
            out.update(type="int[]", ints=[int(v) for v in value])
        elif type_name in ("float[]", "double[]"):
            out.update(type="double[]", doubles=[float(v) for v in value])
        elif type_name in ("string[]", "token[]"):
            out.update(type="string[]", strings=[str(v) for v in value])
    except (TypeError, ValueError):
        pass  # leave as unsupported: preserved, inspectable, never fatal
    return out


def prim_payload(prim):
    from pxr import Usd, UsdGeom
    payload = {
        "path": str(prim.GetPath()),
        "type": prim.GetTypeName() or "",
        "active": prim.IsActive(),
        "visibility": "inherited",
        "attributes": [attribute_payload(a) for a in prim.GetAttributes()],
        "metadata": {},
        "variantSets": [],
        # Include inactive prims: they must stay inspectable in the outliner
        # (PRD §5.3 Deactivate semantics — never silently drop data).
        "children": [prim_payload(c) for c in
                     prim.GetFilteredChildren(Usd.PrimIsDefined)],
    }
    imageable = UsdGeom.Imageable(prim)
    if imageable:
        vis = imageable.GetVisibilityAttr().Get()
        if vis == UsdGeom.Tokens.invisible:
            payload["visibility"] = "invisible"
    kind = prim.GetMetadata("kind")
    if kind:
        payload["metadata"]["kind"] = str(kind)
    for vset_name in prim.GetVariantSets().GetNames():
        vset = prim.GetVariantSets().GetVariantSet(vset_name)
        payload["variantSets"].append({
            "name": vset_name,
            "variants": vset.GetVariantNames(),
            "selection": vset.GetVariantSelection() or None,
        })
    return payload


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: stage_snapshot.py <file.usd[z|a|c]>\n")
        return 2
    try:
        from pxr import Usd, UsdGeom
    except ImportError as exc:
        sys.stderr.write("usd-core not importable: %s\n" % exc)
        return 3
    stage = Usd.Stage.Open(sys.argv[1])
    if stage is None:
        sys.stderr.write("could not open stage: %s\n" % sys.argv[1])
        return 4
    metadata = {
        "upAxis": str(UsdGeom.GetStageUpAxis(stage)),
        "metersPerUnit": float(UsdGeom.GetStageMetersPerUnit(stage)),
    }
    default_prim = stage.GetDefaultPrim()
    if default_prim:
        metadata["defaultPrim"] = default_prim.GetName()
    root = stage.GetPseudoRoot()
    snapshot = {
        "metadata": metadata,
        "prims": [prim_payload(p)
                  for p in root.GetFilteredChildren(Usd.PrimIsDefined)],
    }
    json.dump(snapshot, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
