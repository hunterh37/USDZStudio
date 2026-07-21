#!/bin/bash
# Sculpt-accuracy regression gate (#93 / specs/sculpt-pipeline.md §Accuracy).
#
# Runs `SculptEvalHarness.benchmark()` over the frozen P0 labelled corpus
# (EvalCorpus) and fails on any drift against the fixtures frozen in
# EvalRegressionTests.swift. This is the *same* metric the live continue-gate
# uses, so a change that would move the gate is caught here before it ships.
#
# The gate is red on drift in EITHER direction (same ratchet discipline as
# roundtrip-gate.sh / coverage-gate.sh):
#   • a measured quantity that drops   → a real accuracy regression;
#   • a measured quantity that rises    → the metric moved, so the frozen
#     fixtures must be re-frozen in the same commit — progress is never silent.
#
# Pure Swift (SculptKit has no usd-core / GPU / imaging dependency), so this
# runs fast and needs no Python runtime.
#
# Usage: scripts/sculpt-eval-gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "──── sculpt-accuracy regression: SculptEvalHarness over the P0 corpus"
if swift test --package-path Packages/SculptKit \
     --filter EvalRegressionTests 2>&1 | tee /dev/stderr | grep -q "Test run with .* passed"; then
  echo
  echo "Sculpt-accuracy regression gate passed."
else
  echo
  echo "Sculpt-accuracy regression gate FAILED — harness numbers drifted from the" >&2
  echo "frozen fixtures in EvalRegressionTests.swift. If the metric changed on" >&2
  echo "purpose, re-freeze the fixtures in the same commit (#93 discipline)." >&2
  exit 1
fi
