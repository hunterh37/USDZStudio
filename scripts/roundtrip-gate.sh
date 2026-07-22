#!/bin/bash
# Round-trip invariant gate (ROADMAP Milestone 4 / specs/testing.md §Test Layers 4).
#
# Runs `openusdz roundtrip --strict` over the committed bridge mini-corpus and
# compares each invariant against the EXPECTATIONS table below. The gate is red
# when reality disagrees with the table in *either* direction:
#
#   • a declared-passing invariant that starts failing  → a real regression;
#   • a declared-failing invariant that starts passing  → the gap closed, so the
#     table must be tightened (same ratchet discipline as coverage-gate.sh —
#     a known gap can never quietly widen, and progress can never go unrecorded).
#
# Invariants per file (see CLI/Sources/RoundTripCommand.swift for the contract):
#   idempotent  — open → save → open is a fixed point on the editor's model.
#   editundo    — open → edit → undo-all → save lands back on the opened model.
#   strict      — the flattened USD *text* matches the original file.
#
# Usage: scripts/roundtrip-gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CORPUS="Packages/USDBridge/Tests/USDBridgeTests/Fixtures/Corpus"
BIN="CLI/.build/debug/openusdz"

# ── Expectations: "<file>|<idempotent>|<editundo>|<strict>"   (yes | no)
#
# Two known, pre-existing model gaps keep `strict` at "no" across the board and
# `idempotent` at "no" for two fixtures. Both are authoring-phase work, tracked
# in ROADMAP Phases 10/12 — not Milestone 4 scope. They are recorded here so the
# loss is enforced and visible rather than silent:
#
#   • USDASerializer emits no `variantSet` blocks, so variant sets are dropped on
#     save (variants.usda). — ROADMAP Phase 12 (advanced composition).
#   • Attributes the bridge surfaces as `.unsupported` (a purely time-sampled
#     channel has no default-time value) are written as an "omitted" comment, so
#     their values are dropped on save (animated.usda). — ROADMAP Phase 10.
#
# `strict` is "no" everywhere because the editor's model is a deliberate subset
# of USD: re-serializing materializes computed attributes (purpose, visibility)
# and omits unsupported ones, so flattened text is never byte-equivalent yet.
EXPECTATIONS=(
  "cube.usda|yes|yes|no"
  "cube.usdz|yes|yes|no"
  "subdiv_quads.usda|yes|yes|no"   # pure-quad refined mesh (subdivide) — issue #92
  "variants.usda|no|yes|no"     # variant sets dropped on save — Phase 12
  "skel.usda|yes|yes|no"
  "skel.usdz|yes|yes|no"
  "animated.usda|no|yes|no"     # time-sampled values dropped on save — Phase 10
  "capture-object.usda|yes|yes|no"   # photogrammetry capture result — geometry-only mesh (specs/capture-import.md)
)
# Files that must FAIL to open at all (malformed input must never be silently
# accepted, and must never crash the harness).
MUST_NOT_OPEN=("malformed.usda")

# Locally, a missing usd-core is a skip so the gate never blocks a dev without
# the runtime. In CI it must be a hard failure — a gate that silently passes
# when its dependency is absent is worse than no gate ("green" must mean
# "actually checked"). CI sets ROUNDTRIP_REQUIRE_USD=1.
if ! python3 -c 'import pxr' 2>/dev/null; then
  if [[ "${ROUNDTRIP_REQUIRE_USD:-0}" == "1" ]]; then
    echo "roundtrip-gate: FAILED — usd-core is required here but not importable." >&2
    exit 1
  fi
  echo "roundtrip-gate: skipped — no usd-core in python3 (pip install usd-core)" >&2
  exit 0
fi

echo "──── build: openusdz"
(cd CLI && swift build >/dev/null)

fail=0

for row in "${EXPECTATIONS[@]}"; do
  IFS='|' read -r file want_idem want_undo want_strict <<< "$row"
  path="$CORPUS/$file"
  if [[ ! -f "$path" ]]; then
    echo "  ✗ $file: missing from the corpus"
    fail=1
    continue
  fi
  # Exit code is non-zero whenever any invariant fails, which is expected for
  # rows with a "no" — so read the JSON report rather than the exit status.
  json="$("$BIN" roundtrip "$path" --strict --json || true)"
  read -r got_idem got_undo got_strict <<< "$(printf '%s' "$json" | python3 -c '
import json, sys
r = json.load(sys.stdin)["reports"][0]
def yn(v): return "yes" if v else "no"
print(yn(r["idempotent"]), yn(r["editUndoNeutral"]), yn(r.get("strictTextClean", False)))
')"

  for pair in "idempotent:$want_idem:$got_idem" \
              "editundo:$want_undo:$got_undo" \
              "strict:$want_strict:$got_strict"; do
    IFS=':' read -r name want got <<< "$pair"
    if [[ "$want" == "$got" ]]; then
      echo "  ✓ $file $name=$got"
    elif [[ "$want" == "yes" ]]; then
      echo "  ✗ $file $name: REGRESSION — expected pass, got fail"
      fail=1
    else
      echo "  ✗ $file $name: now PASSES — tighten EXPECTATIONS in $0 to 'yes'"
      fail=1
    fi
  done
done

for file in "${MUST_NOT_OPEN[@]}"; do
  if "$BIN" roundtrip "$CORPUS/$file" >/dev/null 2>&1; then
    echo "  ✗ $file: malformed input opened cleanly — it must be rejected"
    fail=1
  else
    echo "  ✓ $file rejected as expected"
  fi
done

echo
if [[ $fail -ne 0 ]]; then
  echo "Round-trip gate FAILED (ROADMAP Milestone 4 / specs/testing.md)."
  exit 1
fi
echo "Round-trip gate passed."
