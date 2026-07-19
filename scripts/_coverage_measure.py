#!/usr/bin/env python3
"""Measure line coverage for one module against a floor.

Args: <codecov.json> <source_dir_abs> <floor:int> <report:0|1>

Prints per-file coverage, an excluded-region manifest, and a line
"MODULE_PCT=<n>" the caller greps. Exits 1 if measured coverage is below the
floor (unless report mode), matching the old MeshKit-only gate's contract for
the 100% case (uncovered lines listed) and extending it to sub-100 floors.
"""
import json, os, re, sys
from collections import defaultdict

codecov_path, source_dir, floor_s, report_s = sys.argv[1:5]
floor = float(floor_s)
report = report_s == "1"
source_dir = os.path.abspath(source_dir)

ANNOTATION = re.compile(r"//\s*coverage:disable\s*[—-]\s*(.+)")
ENABLE = re.compile(r"//\s*coverage:enable\b")


def excluded_lines(source_path):
    """Two annotation forms, both requiring a reason on the disable line:

    1. Block-region: `// coverage:disable — reason` … `// coverage:enable`
       excludes every line in between (inclusive). Use for whole subprocess/glue
       functions whose nested braces the brace form can't span.
    2. Brace form (no matching enable before the next closing brace): excludes
       from the annotation through the enclosing block's closing `}` (exclusive
       of the brace line). Use for small defensive guards.
    """
    excluded, manifest = set(), []
    lines = open(source_path).read().splitlines()
    i = 0
    while i < len(lines):
        m = ANNOTATION.search(lines[i])
        if m:
            start = i
            # Look ahead for an explicit enable terminator. Scan past braces so a
            # region can span a whole function; stop only at the next disable
            # annotation (which starts its own region) or EOF.
            j = i + 1
            found_enable = None
            while j < len(lines):
                if ENABLE.search(lines[j]):
                    found_enable = j
                    break
                if ANNOTATION.search(lines[j]):
                    break  # next disable begins; treat this one as brace form
                j += 1
            if found_enable is not None:
                for k in range(i, found_enable + 1):
                    excluded.add(k + 1)
                i = found_enable  # outer i += 1 advances past the enable line
            else:
                while i < len(lines) and lines[i].strip() != "}":
                    excluded.add(i + 1)  # 1-indexed
                    i += 1
            manifest.append((start + 1, m.group(1).strip()))
        i += 1
    return excluded, manifest


data = json.load(open(codecov_path))["data"][0]

total_lines = 0
covered_lines = 0
all_manifest = []
file_reports = []
uncovered_detail = []

for f in sorted(data["files"], key=lambda f: f["filename"]):
    fn = f["filename"]
    if not os.path.abspath(fn).startswith(source_dir + os.sep):
        continue
    rel = fn.split("/Packages/")[-1] if "/Packages/" in fn else fn.split("/")[-1]

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

    instrumented = [(L, c) for L, c in line_max.items() if L not in excluded]
    f_total = len(instrumented)
    f_covered = sum(1 for _, c in instrumented if c > 0)
    total_lines += f_total
    covered_lines += f_covered

    uncovered = [L for L, c in sorted(instrumented) if c == 0]
    pct = 100.0 if f_total == 0 else 100.0 * f_covered / f_total
    file_reports.append((rel, pct, f_covered, f_total))
    if uncovered:
        src = open(fn).read().splitlines()
        uncovered_detail.append((rel, [(L, src[L - 1].strip()) for L in uncovered]))

module_pct = 100.0 if total_lines == 0 else 100.0 * covered_lines / total_lines

for rel, pct, cov, tot in file_reports:
    mark = "✓" if pct >= floor else "✗"
    print(f"    {mark} {rel}: {pct:.1f}% ({cov}/{tot})")

# For a 100 floor, surface exactly which lines are uncovered (old behavior).
if floor >= 100 and uncovered_detail:
    for rel, lines in uncovered_detail:
        print(f"    uncovered in {rel}:")
        for L, txt in lines:
            print(f"      {L}: {txt}")

if all_manifest:
    print("    excluded-region manifest (review every entry):")
    for rel, ln, why in all_manifest:
        print(f"      {rel}:{ln} — {why}")

print(f"  MODULE_PCT={module_pct:.1f}  ({covered_lines}/{total_lines} lines)")

if not report and module_pct + 1e-9 < floor:
    print(f"  ✗ {module_pct:.1f}% is below floor {floor:.0f}%")
    sys.exit(1)
