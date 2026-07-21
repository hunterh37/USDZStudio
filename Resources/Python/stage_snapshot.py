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
        elif type_name in ("point3f[]", "normal3f[]", "vector3f[]", "float3[]",
                           "double3[]", "color3f[]"):
            # Flattened xyz triples — mesh points/normals (Phase 6 mesh editing
            # reads these; without them no opened file could enter edit mode).
            out.update(type="float3[]",
                       doubles=[float(c) for v in value for c in v])
        elif type_name in ("texCoord2f[]", "float2[]", "double2[]"):
            out.update(type="double[]",
                       doubles=[float(c) for v in value for c in v])
        elif type_name in ("int[]", "uint[]"):
            out.update(type="int[]", ints=[int(v) for v in value])
        elif type_name in ("float[]", "double[]"):
            out.update(type="double[]", doubles=[float(v) for v in value])
        elif type_name in ("string[]", "token[]"):
            out.update(type="string[]", strings=[str(v) for v in value])
    except (TypeError, ValueError):
        pass  # leave as unsupported: preserved, inspectable, never fatal
    return out


def relationship_payload(rel):
    # Targets are Sdf paths; property targets (e.g. a connection to
    # </Looks/M/Surface.outputs:surface>) are pruned to their prim path so the
    # editor's PrimPath can hold them. A relationship whose targets are all
    # unusable still ships, with an empty target list, rather than vanishing.
    targets = []
    for path in rel.GetTargets():
        prim_path = path.GetPrimPath()
        if prim_path and not prim_path.isEmpty:
            targets.append(str(prim_path))
    return {
        "name": rel.GetName(),
        "targets": targets,
        "uniform": True,  # relationships are always uniform in USD
    }


def prim_payload(prim):
    from pxr import Usd, UsdGeom
    payload = {
        "path": str(prim.GetPath()),
        "type": prim.GetTypeName() or "",
        "active": prim.IsActive(),
        "visibility": "inherited",
        "attributes": [attribute_payload(a) for a in prim.GetAttributes()],
        # Relationships carry material:binding and skel:skeleton — without them
        # the inspector can't tell which material a mesh renders with. Authored
        # only: GetRelationships() also returns unauthored schema built-ins
        # (every Imageable declares proxyPrim), which would show the user a
        # wall of empty rows for opinions the file doesn't hold.
        "relationships": [relationship_payload(r)
                          for r in prim.GetAuthoredRelationships()],
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


class SnapshotError(Exception):
    """Carries a process-style exit code alongside the message, so both the
    one-shot CLI and the persistent server report the same failures."""
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def build_snapshot(path):
    """Open `path` and return its snapshot dict — the single source of truth for
    the wire format, shared by `main()` (one-shot) and `bridge_server.py` (the
    long-lived worker). Raises `SnapshotError(code, message)` on failure.
    """
    try:
        from pxr import Usd, UsdGeom
    except ImportError as exc:
        raise SnapshotError(3, "usd-core not importable: %s" % exc)
    stage = Usd.Stage.Open(path)
    if stage is None:
        raise SnapshotError(4, "could not open stage: %s" % path)
    metadata = {
        "upAxis": str(UsdGeom.GetStageUpAxis(stage)),
        "metersPerUnit": float(UsdGeom.GetStageMetersPerUnit(stage)),
    }
    default_prim = stage.GetDefaultPrim()
    if default_prim:
        metadata["defaultPrim"] = default_prim.GetName()
    root = stage.GetPseudoRoot()
    return {
        "metadata": metadata,
        "prims": [prim_payload(p)
                  for p in root.GetFilteredChildren(Usd.PrimIsDefined)],
    }


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: stage_snapshot.py <file.usd[z|a|c]>\n")
        return 2
    try:
        snapshot = build_snapshot(sys.argv[1])
    except SnapshotError as err:
        sys.stderr.write(err.message + "\n")
        return err.code
    json.dump(snapshot, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
