#!/bin/bash
# 100%-coverage gate for MeshKit (specs/testing.md, specs/mesh-editing.md §Testing).
#
# Runs the MeshKit suite with coverage and fails if any line in
# Packages/MeshKit/Sources is uncovered. A line counts as covered when any
# instrumented region touching it executed. Defensive lines proven unreachable
# may be excluded with an inline annotation, reviewed in PR:
#
#     // coverage:disable — <reason>
#
# The annotation excludes lines from the comment to the enclosing block's
# closing brace. CI prints the excluded-region manifest so reviewers see every
# exclusion on every run.
set -euo pipefail
cd "$(dirname "$0")/../Packages/MeshKit"

echo "──── coverage gate: MeshKit (floor: 100%)"
swift test --enable-code-coverage >/dev/null
CODECOV_JSON="$(swift test --show-codecov-path)"

python3 - "$CODECOV_JSON" <<'PY'
import json, os, re, sys
from collections import defaultdict

codecov_path = sys.argv[1]
data = json.load(open(codecov_path))["data"][0]

ANNOTATION = re.compile(r"//\s*coverage:disable\s*[—-]\s*(.+)")

def excluded_lines(source_path):
    """Annotation line through the next closing-brace line (exclusive)."""
    excluded, manifest = set(), []
    lines = open(source_path).read().splitlines()
    i = 0
    while i < len(lines):
        m = ANNOTATION.search(lines[i])
        if m:
            start = i
            while i < len(lines) and lines[i].strip() != "}":
                excluded.add(i + 1)  # 1-indexed
                i += 1
            manifest.append((start + 1, m.group(1).strip()))
        i += 1
    return excluded, manifest

failed = False
all_manifest = []
for f in sorted(data["files"], key=lambda f: f["filename"]):
    fn = f["filename"]
    if "/Sources/MeshKit/" not in fn:
        continue
    rel = fn.split("/Packages/")[-1]

    line_max = defaultdict(lambda: -1)
    segs = f["segments"]
    for i, s in enumerate(segs):
        line, col, count, has_count, is_entry, is_gap = s
        if not has_count or is_gap:
            continue
        end = segs[i + 1][0] if i + 1 < len(segs) else line
        for L in range(line, end + 1):
            line_max[L] = max(line_max[L], count)

    excluded, manifest = excluded_lines(fn)
    all_manifest += [(rel, ln, why) for ln, why in manifest]
    uncovered = [L for L, c in sorted(line_max.items()) if c == 0 and L not in excluded]
    if uncovered:
        failed = True
        print(f"✗ {rel}: uncovered lines {uncovered}")
        src = open(fn).read().splitlines()
        for L in uncovered:
            print(f"    {L}: {src[L-1].strip()}")
    else:
        print(f"✓ {rel}: 100%")

if all_manifest:
    print("\nExcluded-region manifest (review every entry):")
    for rel, ln, why in all_manifest:
        print(f"  {rel}:{ln} — {why}")

if failed:
    print("\nCoverage gate FAILED: MeshKit is held to 100% line coverage.")
    sys.exit(1)
print("\nCoverage gate passed.")
PY
