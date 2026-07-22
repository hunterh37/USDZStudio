#!/bin/bash
# Data-driven per-module coverage gate (specs/testing.md §Per-Module Coverage Floors).
#
# Each module below carries a floor. The gate runs that module's suite with
# coverage and fails if measured line coverage over its Sources/ tree drops
# below the floor. A 100 floor means *every* line must be covered; a sub-100
# floor means (covered / instrumented) lines must meet or exceed the percentage.
#
# Defensive lines proven unreachable may be excluded with an inline annotation,
# reviewed in PR:
#
#     // coverage:disable — <reason>
#
# The annotation excludes lines from the comment through the enclosing block's
# closing brace. Excluded lines are removed from BOTH numerator and denominator,
# and every exclusion is printed as a manifest on each run so reviewers see them.
#
# Usage:
#   scripts/coverage-gate.sh            # gate: fail if any module is below floor
#   scripts/coverage-gate.sh --report   # measure & print only, never fail (CI-safe audit)
#   scripts/coverage-gate.sh MeshKit    # gate a single module by name
#
# The MODULES table is the machine-checked mirror of the floors table in
# specs/testing.md; the two must change in the same PR.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ── Floors table: "<name>|<package-dir>|<source-subpath>|<floor>"
#
# Two kinds of floor live here:
#   • SPEC floors — the target from specs/testing.md, currently MET and enforced.
#   • RATCHET floors — a regression barrier pinned at today's measured coverage
#     for modules still below their spec target. The spec target is noted inline;
#     the gap is tracked in ROADMAP Phase T. Raise the ratchet as coverage climbs;
#     never lower it. The ratchet only rises — it can't be used to hide a drop.
#
# ViewportKit/EditorUI are far below their 90% spec floor because that floor
# assumes the golden-image + snapshot + XCUITest harnesses (specs/testing.md
# §Test Layers 6–8), which don't exist yet. USDBridge graduated from ratchet to
# its 95% spec floor in Milestone 4, once the bridge mini-corpus and real
# usd-core save-path round-trip tests covered the StageSaver path.
MODULES=(
  # Spec floors — met and enforced.
  "USDCore|Packages/USDCore|Sources/USDCore|100"
  "MeshKit|Packages/MeshKit|Sources/MeshKit|100"
  "CaptureKit|Packages/CaptureKit|Sources/CaptureKit|100"
  "MechanismKit|Packages/MechanismKit|Sources/MechanismKit|100"
  "RigKit|Packages/RigKit|Sources/RigKit|100"
  "EditingKit|Packages/EditingKit|Sources/EditingKit|100"
  "ValidationKit|Packages/ValidationKit|Sources/ValidationKit|100"
  "ConversionKit|Packages/ConversionKit|Sources/ConversionKit|100"
  "ScriptingKit|Packages/ScriptingKit|Sources/ScriptingKit|100"
  "AgentMCP|Packages/AgentMCP|Sources/AgentMCP|100"
  "SculptKit|Packages/SculptKit|Sources/SculptKit|100"
  "SessionKit|Packages/SessionKit|Sources/SessionKit|100"
  "DicyaninDesignSystem|Packages/DicyaninDesignSystem|Sources/DicyaninDesignSystem|95"
  "QuickLookKit|Packages/QuickLookKit|Sources/QuickLookKit|100"
  "CLI|CLI|Sources|95"
  "USDBridge|Packages/USDBridge|Sources/USDBridge|95"          # spec floor; measures 100 today
  # Ratchet floors — pinned below spec target (noted), gap tracked in ROADMAP Phase T.
  "ViewportKit|Packages/ViewportKit|Sources/ViewportKit|50"    # ratchet 46→50; spec target 90
  "EditorUI|Packages/EditorUI|Sources/EditorUI|64"             # ratchet 34→64; spec target 90
)

REPORT=0
ONLY=""
for arg in "$@"; do
  case "$arg" in
    --report) REPORT=1 ;;
    *) ONLY="$arg" ;;
  esac
done

overall_fail=0
# A module that measured ZERO source files is a gate/config fault, not a low
# score. It fails even in --report mode, which otherwise never fails: report
# mode is for auditing real numbers, and "no number at all" is never a real
# number. Kept separate from overall_fail for exactly that reason.
not_measured=0
summary=()

for row in "${MODULES[@]}"; do
  IFS='|' read -r name pkgdir srcsub floor <<< "$row"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue

  echo "──── coverage: $name (floor: ${floor}%)"
  if [[ ! -d "$ROOT/$pkgdir" ]]; then
    echo "  ✗ package dir $pkgdir missing"
    overall_fail=1; summary+=("$name: MISSING"); continue
  fi

  # --no-parallel is load-bearing, not a speed knob. This is the *measurement*
  # pass, whose entire job is a reproducible number. Under swift-testing's
  # default parallel execution, coverage counters written from the async tool
  # pipeline are intermittently lost: ~8% of runs dropped a covered line group
  # (e.g. AgentMCP's PrimTree collision loop, Tools+Asset normalize path) to
  # zero even though every test passed — producing 90.5%/99.5%/100% across
  # identical runs. It is NOT stale-profraw accumulation (the codecov dir holds
  # a stable two files, overwritten each run). Collecting serially made the
  # number deterministic (0 drops in 80 runs vs ~4 in 50 parallel). The
  # parallel speed win belongs to test-all.sh; a gate that measures a different
  # number each run measures nothing.
  (cd "$ROOT/$pkgdir" && swift test --enable-code-coverage --no-parallel >/dev/null 2>&1) || {
    echo "  ✗ $name test suite failed to build/run"
    overall_fail=1; summary+=("$name: TEST-FAIL"); continue
  }
  # --show-codecov-path only resolves the path today, but keep it serial so it
  # can never re-run tests in parallel and re-merge a flaky profdata over the one
  # the pass above just produced.
  codecov_json="$(cd "$ROOT/$pkgdir" && swift test --show-codecov-path --no-parallel 2>/dev/null)"

  result="$(python3 "$ROOT/scripts/_coverage_measure.py" \
              "$codecov_json" "$ROOT/$pkgdir/$srcsub" "$floor" "$REPORT")" || {
    echo "$result"
    overall_fail=1
    if [[ "$result" == *"NOT MEASURED"* ]]; then
      not_measured=1; summary+=("$name: NOT-MEASURED (gate fault)")
    else
      summary+=("$name: BELOW-FLOOR")
    fi
    continue
  }
  echo "$result"
  pct="$(echo "$result" | sed -n 's/.*MODULE_PCT=\([0-9.]*\).*/\1/p')"
  summary+=("$name: ${pct}% (floor ${floor}%)")
done

echo ""
echo "──── coverage summary"
for s in "${summary[@]}"; do echo "  $s"; done

if [[ "$not_measured" == "1" ]]; then
  echo ""
  echo "Coverage gate FAILED — a module measured zero source files."
  echo "This is a gate/config fault: nothing was measured, so nothing is proven."
  exit 1
fi
if [[ "$REPORT" == "1" ]]; then
  echo ""
  echo "(report mode — no gate enforced)"
  exit 0
fi
if [[ "$overall_fail" == "1" ]]; then
  echo ""
  echo "Coverage gate FAILED — one or more modules below floor (specs/testing.md)."
  exit 1
fi
echo ""
echo "Coverage gate passed."
