"""Remove Hidden Prims — prune invisible geometry before shipping.

DCC exports routinely leave behind prims marked invisible (guides, proxies,
alternate LODs turned off). They add bytes and load time but never render.
This finds prims whose resolved visibility is `invisible` and, by default,
deactivates them (safe, reversible, keeps data inspectable per PRD §5.3);
pass --mode remove to delete them outright for a smaller shipping file.

Mutating. Operates on the selection subtree(s) if any, else the whole stage.
"""

from _harness import begin, finish

MANIFEST = {
    "name": "Remove Hidden Prims",
    "description": "Deactivate or delete invisible prims to slim the asset.",
    "mutates": True,
    "args": [
        {"name": "mode", "type": "str", "default": "deactivate",
         "help": "'deactivate' (reversible) or 'remove' (delete specs)."},
    ],
}


def _invisible(prim):
    from pxr import UsdGeom
    imageable = UsdGeom.Imageable(prim)
    if not imageable:
        return False
    vis = imageable.ComputeVisibility()
    return vis == UsdGeom.Tokens.invisible


def main():
    ctx = begin(globals(), MANIFEST)
    mode = (ctx.args.mode or "deactivate").lower()
    if mode not in ("deactivate", "remove"):
        raise ValueError("mode must be 'deactivate' or 'remove', got %r" % mode)

    # Collect first; editing while traversing is unsafe. Skip descendants of an
    # already-collected prim — pruning the ancestor takes the subtree with it.
    targets = []
    for prim in ctx.prims():
        if _invisible(prim):
            path = prim.GetPath()
            if not any(path.HasPrefix(t) and path != t for t in targets):
                targets.append(path)

    for path in targets:
        prim = ctx.stage.GetPrimAtPath(path)
        if not prim or not prim.IsValid():
            continue
        if mode == "deactivate":
            prim.SetActive(False)
        else:
            ctx.stage.RemovePrim(path)

    verb = "deactivated" if mode == "deactivate" else "removed"
    ctx.app.log("%s %d hidden prim(s)" % (verb, len(targets)))
    finish(ctx)


if __name__ == "__main__" or globals().get("stage") is not None:
    main()
