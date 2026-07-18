"""Shared runtime harness for OpenUSDZEditor bundled scripts.

Every bundled script targets *two* execution modes without changing its body:

1. In-app Python console (specs/scripting.md) — the host execs the script with
   injected globals ``stage`` (live Usd.Stage), ``selection`` (list of prim
   paths) and ``app`` (facade with .select/.frame/.run_command/.log/.progress).
   Mutations are wrapped by the host into a single undo step.

2. Headless CLI — ``openusdz run script.py model.usdz [--flags]`` (and plain
   ``python3 script.py model.usdz``). Here we open the stage ourselves, parse
   flags from the script's MANIFEST, and save on exit unless --dry-run.

A script uses the harness like this::

    from _harness import begin, finish

    MANIFEST = {
        "name": "Strip Animations",
        "description": "Bake time-sampled attributes down to a static pose.",
        "mutates": True,
        "args": [{"name": "frame", "type": "float", "default": None,
                  "help": "Frame to freeze on (default: stage start)."}],
    }

    ctx = begin(globals(), MANIFEST)
    for prim in ctx.prims():
        ...
    finish(ctx)

Underscore-prefixed files are treated as private helpers and hidden from the
Scripts panel, so this module never shows up as a runnable script.
"""

import argparse
import os
import sys


class ScriptContext:
    """Everything a script needs, uniform across injected and headless modes."""

    def __init__(self, stage, selection, app, args, mutates, output, dry_run,
                 injected):
        self.stage = stage
        self.selection = list(selection)
        self.app = app
        self.args = args          # argparse.Namespace of MANIFEST args
        self.mutates = mutates
        self.output = output      # headless-only: where finish() writes
        self.dry_run = dry_run
        self.injected = injected

    def prims(self):
        """Prims to operate on: the selection if any, else the whole stage.

        Mirrors the console's mental model — a script with nothing selected
        acts on the entire document.
        """
        from pxr import Usd
        if self.selection:
            out = []
            for path in self.selection:
                prim = self.stage.GetPrimAtPath(path)
                if prim and prim.IsValid():
                    out.append(prim)
            return out
        return [p for p in self.stage.Traverse()
                if p.GetPath() != Usd.Stage.GetPseudoRoot(self.stage).GetPath()]


class _HeadlessApp:
    """Minimal stand-in for the injected `app` facade when running headless.

    Everything routes to stderr so stdout stays clean for JSON/report output
    (same discipline as stage_snapshot.py).
    """

    def __init__(self):
        self._selection = []

    def select(self, paths):
        self._selection = [str(p) for p in (paths or [])]

    def frame(self):
        pass  # no viewport headless

    def run_command(self, *_args, **_kwargs):
        # EditingKit commands live in the app process; headless scripts mutate
        # the stage directly via pxr instead.
        raise RuntimeError("app.run_command is only available in the in-app "
                           "console; edit the stage via pxr when running "
                           "headless.")

    def log(self, *parts):
        sys.stderr.write(" ".join(str(p) for p in parts) + "\n")

    def progress(self, fraction, message=""):
        sys.stderr.write("[%3d%%] %s\n" % (int(max(0.0, min(1.0, fraction)) * 100),
                                           message))


def _build_parser(manifest):
    parser = argparse.ArgumentParser(
        prog=manifest.get("name", "script"),
        description=manifest.get("description", ""))
    parser.add_argument("input", help="USD/USDZ file to operate on")
    if manifest.get("mutates"):
        parser.add_argument("-o", "--output", default=None,
                             help="Write result here (default: in place)")
        parser.add_argument("--dry-run", action="store_true",
                             help="Report intended changes without saving")
    _types = {"int": int, "float": float, "str": str}
    for spec in manifest.get("args", []):
        name = spec["name"]
        kind = spec.get("type", "str")
        default = spec.get("default")
        help_text = spec.get("help", "")
        if kind == "bool":
            parser.add_argument("--" + name.replace("_", "-"),
                                dest=name, action="store_true", help=help_text)
        else:
            parser.add_argument("--" + name.replace("_", "-"), dest=name,
                                type=_types.get(kind, str), default=default,
                                help=help_text + (" (default: %s)" % default
                                                  if default is not None else ""))
    return parser


def _injected_args(manifest, g):
    """In-console mode: the param sheet passes values via an ARGS dict; fall
    back to MANIFEST defaults for anything unset."""
    provided = g.get("ARGS", {}) or {}
    ns = argparse.Namespace()
    for spec in manifest.get("args", []):
        name = spec["name"]
        setattr(ns, name, provided.get(name, spec.get("default")))
    return ns


def begin(g, manifest):
    """Resolve the execution context. `g` is the caller's globals()."""
    injected = g.get("stage") is not None
    mutates = bool(manifest.get("mutates"))

    if injected:
        app = g.get("app") or _HeadlessApp()
        return ScriptContext(
            stage=g["stage"],
            selection=g.get("selection", []) or [],
            app=app,
            args=_injected_args(manifest, g),
            mutates=mutates,
            output=None,
            dry_run=False,
            injected=True,
        )

    # Headless.
    from pxr import Usd
    parser = _build_parser(manifest)
    ns = parser.parse_args(sys.argv[1:])
    if not os.path.exists(ns.input):
        parser.error("no such file: %s" % ns.input)
    stage = Usd.Stage.Open(ns.input)
    if stage is None:
        parser.error("could not open stage: %s" % ns.input)
    return ScriptContext(
        stage=stage,
        selection=[],
        app=_HeadlessApp(),
        args=ns,
        mutates=mutates,
        output=getattr(ns, "output", None),
        dry_run=getattr(ns, "dry_run", False),
        injected=False,
    )


def finish(ctx):
    """Persist changes when appropriate.

    Injected: no-op — the host owns saving and the single-undo boundary.
    Headless: save in place, or to --output, unless --dry-run.
    """
    if ctx.injected or not ctx.mutates:
        return
    if ctx.dry_run:
        ctx.app.log("dry-run: no file written")
        return
    if ctx.output:
        _export(ctx.stage, ctx.output)
        ctx.app.log("wrote", ctx.output)
    else:
        ctx.stage.GetRootLayer().Save()
        ctx.app.log("saved in place:", ctx.stage.GetRootLayer().identifier)


def _export(stage, output):
    """Export the composed stage to output, packaging as .usdz when asked."""
    from pxr import UsdUtils
    ext = os.path.splitext(output)[1].lower()
    if ext == ".usdz":
        flat = stage.Flatten()
        tmp = output + ".flat.usdc"
        flat.Export(tmp)
        UsdUtils.CreateNewUsdzPackage(tmp, output)
        try:
            os.remove(tmp)
        except OSError:
            pass
    else:
        stage.Export(output)
