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
# §Test Layers 6–8), which don't exist yet. USDBridge's StageSaver save path
# needs real-usd-core round-trip integration tests to reach 95%.
MODULES=(
  # Spec floors — met and enforced.
  "USDCore|Packages/USDCore|Sources/USDCore|100"
  "MeshKit|Packages/MeshKit|Sources/MeshKit|100"
  "EditingKit|Packages/EditingKit|Sources/EditingKit|100"
  "ValidationKit|Packages/ValidationKit|Sources/ValidationKit|100"
  "ConversionKit|Packages/ConversionKit|Sources/ConversionKit|100"
  "ScriptingKit|Packages/ScriptingKit|Sources/ScriptingKit|100"
  "AgentMCP|Packages/AgentMCP|Sources/AgentMCP|100"
  "DicyaninDesignSystem|Packages/DicyaninDesignSystem|Sources/DicyaninDesignSystem|95"
  "QuickLookKit|Packages/QuickLookKit|Sources/QuickLookKit|100"
  "CLI|CLI|Sources|95"
  # Ratchet floors — pinned below spec target (noted), gap tracked in ROADMAP Phase T.
  "USDBridge|Packages/USDBridge|Sources/USDBridge|90"          # spec target 95
  "ViewportKit|Packages/ViewportKit|Sources/ViewportKit|40"    # spec target 90
  "EditorUI|Packages/EditorUI|Sources/EditorUI|27"             # spec target 90
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
summary=()

for row in "${MODULES[@]}"; do
  IFS='|' read -r name pkgdir srcsub floor <<< "$row"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue

  echo "──── coverage: $name (floor: ${floor}%)"
  if [[ ! -d "$ROOT/$pkgdir" ]]; then
    echo "  ✗ package dir $pkgdir missing"
    overall_fail=1; summary+=("$name: MISSING"); continue
  fi

  (cd "$ROOT/$pkgdir" && swift test --enable-code-coverage >/dev/null 2>&1) || {
    echo "  ✗ $name test suite failed to build/run"
    overall_fail=1; summary+=("$name: TEST-FAIL"); continue
  }
  codecov_json="$(cd "$ROOT/$pkgdir" && swift test --show-codecov-path 2>/dev/null)"

  result="$(python3 "$ROOT/scripts/_coverage_measure.py" \
              "$codecov_json" "$ROOT/$pkgdir/$srcsub" "$floor" "$REPORT")" || {
    echo "$result"
    overall_fail=1; summary+=("$name: BELOW-FLOOR"); continue
  }
  echo "$result"
  pct="$(echo "$result" | sed -n 's/.*MODULE_PCT=\([0-9.]*\).*/\1/p')"
  summary+=("$name: ${pct}% (floor ${floor}%)")
done

echo ""
echo "──── coverage summary"
for s in "${summary[@]}"; do echo "  $s"; done

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
