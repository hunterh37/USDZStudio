#!/bin/bash
# End-to-end flow gate (specs/testing.md §Test Layer 11 / specs/e2e-testing.md).
#
# Drives whole user journeys through the real product seam — the `openusdz mcp`
# JSON-RPC server (--no-relay, so it serves the fixture headless and never
# attaches to a developer's open document) against the real embedded usd-core
# bridge. Each scenario in Tests/E2E/scenarios/*.json composes the major feature
# tools end to end and asserts on the resulting scene, verdicts, and undo/redo
# behaviour — the cross-feature correctness that per-module line coverage cannot
# see.
#
# Ratchet discipline, identical to roundtrip-gate.sh: every scenario has a
# declared outcome in the EXPECTATIONS table and the gate is red when reality
# disagrees in *either* direction — a declared-pass scenario that fails is a
# regression; a declared-fail scenario that starts passing means the table must
# be tightened. A flow can neither rot silently nor improve unrecorded.
#
# Scenarios run against a *temp copy* of Tests/E2E so a scenario's `save` step
# (which writes to its source stage) never mutates the committed fixtures.
#
# Usage: scripts/e2e-gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SCENARIO_DIR="Tests/E2E/scenarios"
BIN="CLI/.build/debug/openusdz"
DRIVER="scripts/e2e_driver.py"

# ── Expectations: "<scenario-file>|<pass|fail>"
#
# Every major flow the editor exposes through the agent/MCP surface gets a row.
# All pass today; a row flips to `fail` only to record a known, tracked gap
# (with a trailing comment and a ROADMAP reference), never to silence a break.
EXPECTATIONS=(
  "authoring.json|pass"     # create geometry → bind material → validate → save
  "undo-redo.json|pass"     # edit / undo / redo neutrality via the command stack
  "variants.json|pass"      # read variant sets → switch selection → confirm
  "validation.json|pass"    # validate + ARKit compliance gate + error handling
)

# A missing usd-core is a local skip so the gate never blocks a dev without the
# runtime; in CI it is a hard failure (green must mean actually-checked). CI sets
# E2E_REQUIRE_USD=1 and puts the bundled runtime on PATH.
if ! python3 -c 'import pxr' 2>/dev/null; then
  if [[ "${E2E_REQUIRE_USD:-0}" == "1" ]]; then
    echo "e2e-gate: FAILED — usd-core is required here but not importable." >&2
    exit 1
  fi
  echo "e2e-gate: skipped — no usd-core in python3 (run scripts/fetch-python-runtime.sh)" >&2
  exit 0
fi

echo "──── build: openusdz"
(cd CLI && swift build >/dev/null)
BIN_ABS="$PWD/$BIN"

# Sandbox: each scenario runs against its own throwaway copy of the fixtures, so
# a scenario's `save` step (which writes to its source stage) can neither touch
# the committed fixtures nor leak into the next scenario in this run.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
for row in "${EXPECTATIONS[@]}"; do
  IFS='|' read -r file want <<< "$row"
  if [[ ! -f "$SCENARIO_DIR/$file" ]]; then
    echo "  ✗ $file: missing from $SCENARIO_DIR"
    fail=1
    continue
  fi
  sandbox="$WORK/${file%.json}"
  rm -rf "$sandbox"
  cp -R Tests/E2E "$sandbox"
  path="$sandbox/scenarios/$file"
  if [[ ! -f "$path" ]]; then
    echo "  ✗ $file: missing from $SCENARIO_DIR"
    fail=1
    continue
  fi

  if python3 "$DRIVER" --bin "$BIN_ABS" "$path" >/tmp/e2e.out 2>&1; then
    got="pass"
  else
    got="fail"
  fi
  cat /tmp/e2e.out

  if [[ "$want" == "$got" ]]; then
    :
  elif [[ "$want" == "pass" ]]; then
    echo "  ✗ $file: REGRESSION — expected pass, got fail"
    fail=1
  else
    echo "  ✗ $file: now PASSES — tighten EXPECTATIONS in $0 to 'pass'"
    fail=1
  fi
done

echo
if [[ $fail -ne 0 ]]; then
  echo "E2E flow gate FAILED (specs/testing.md §Test Layer 11)."
  exit 1
fi
echo "E2E flow gate passed."
