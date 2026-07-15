"""Batch Rename — regex rename prims across the selection or whole stage.

Imported assets often arrive with names like `Mesh_001`, `pCube12` or
`node_final_v3`. This applies a regex find/replace to prim *names* (not full
paths) in one namespace-edit pass, with collision-safe fallbacks so two prims
never end up fighting for the same name.

Mutating. Operates on the selection if any, else the whole stage.
"""

import re

from _harness import begin, finish

MANIFEST = {
    "name": "Batch Rename",
    "description": "Regex find/replace across prim names.",
    "mutates": True,
    "args": [
        {"name": "pattern", "type": "str", "default": r"^(.*)$",
         "help": "Regex matched against each prim name."},
        {"name": "replace", "type": "str", "default": r"\1",
         "help": "Replacement (supports backrefs like \\1)."},
        {"name": "lower", "type": "bool", "default": False,
         "help": "Lowercase the result after substitution."},
    ],
}


def _sanitize(name):
    """USD prim names must be valid identifiers: alnum + underscore, not
    leading-digit. Keep renames from producing illegal names."""
    name = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if name and name[0].isdigit():
        name = "_" + name
    return name or "_"


def main():
    from pxr import Sdf
    ctx = begin(globals(), MANIFEST)
    rx = re.compile(ctx.args.pattern)

    # Plan every rename first, tracking taken sibling names to dodge collisions.
    used = {}          # parent path -> set of taken child names
    renames = []       # (path, new_name)
    for prim in ctx.prims():
        old = prim.GetName()
        new = rx.sub(ctx.args.replace, old)
        if ctx.args.lower:
            new = new.lower()
        new = _sanitize(new)
        if new == old:
            continue
        parent = prim.GetPath().GetParentPath()
        taken = used.setdefault(parent, set())
        candidate, i = new, 1
        while candidate in taken:      # avoid sibling collisions
            candidate = "%s_%d" % (new, i)
            i += 1
        taken.add(candidate)
        renames.append((prim.GetPath(), candidate))

    # Apply deepest-first, one edit each: renaming a parent re-homes its
    # children automatically, so processing leaves before ancestors keeps every
    # still-pending path valid (a single batch referencing both would orphan
    # the descendant — "Object was removed").
    layer = ctx.stage.GetEditTarget().GetLayer()
    planned = 0
    deepest_first = sorted(renames, key=lambda r: r[0].pathElementCount,
                           reverse=True)
    for path, candidate in deepest_first:
        edit = Sdf.BatchNamespaceEdit()
        edit.Add(Sdf.NamespaceEdit.Rename(path, candidate))
        if not layer.Apply(edit):
            raise RuntimeError("rename failed to apply: %s -> %s" % (path, candidate))
        planned += 1

    ctx.app.log("renamed %d prim(s)" % planned)
    finish(ctx)


if __name__ == "__main__" or globals().get("stage") is not None:
    main()
