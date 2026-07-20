#!/usr/bin/env python3
"""Semantic diff of two USD files — the `usddiff` step of the round-trip gate.

Usage: python3 usd_roundtrip.py <a.usd[a|c|z]> <b.usd[a|c|z]>

Both stages are opened, flattened, and exported to text, then normalized before
comparison so that differences with no semantic meaning (comments, blank lines,
`doc =` strings, and the layer-identifier metadata USD stamps per file) do not
register as changes. Exit 0 when the two are equivalent; 1 with a unified diff
when they are not; 2 on usage/open errors.

This exists because usd-core ships `usddiff` as a shell wrapper around an
external diff tool, which is awkward to depend on in CI. The normalization here
is deliberately conservative: only provably-cosmetic lines are dropped.
"""
import difflib
import re
import sys

# Layer-level metadata that legitimately differs per file and carries no
# stage semantics (the file's own identity and authoring provenance).
_COSMETIC = re.compile(
    r"^\s*(doc\s*=|#|subLayers\s*=\s*\[\s*\]\s*$)"
)


def normalize(text):
    """Drop cosmetic lines and collapse whitespace so the comparison sees
    structure and values only."""
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if _COSMETIC.match(line):
            continue
        # Collapse runs of internal whitespace; USD's text writer is not
        # guaranteed to align identically across formats (usda vs usdc→usda).
        out.append(re.sub(r"\s+", " ", stripped))
    return out


def flatten_to_text(path):
    from pxr import Usd
    stage = Usd.Stage.Open(path)
    if stage is None:
        raise RuntimeError("could not open %s" % path)
    return stage.Flatten().ExportToString()


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: usd_roundtrip.py <a.usd> <b.usd>\n")
        return 2
    a_path, b_path = sys.argv[1], sys.argv[2]
    try:
        from pxr import Usd  # noqa: F401  (import check before doing work)
    except ImportError as exc:
        sys.stderr.write("usd-core not importable: %s\n" % exc)
        return 2
    try:
        a = normalize(flatten_to_text(a_path))
        b = normalize(flatten_to_text(b_path))
    except Exception as exc:  # open/flatten failure is a usage-level error
        sys.stderr.write("error: %s\n" % exc)
        return 2

    if a == b:
        print("CLEAN")
        return 0

    diff = difflib.unified_diff(a, b, fromfile=a_path, tofile=b_path, lineterm="")
    sys.stdout.write("\n".join(diff) + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
