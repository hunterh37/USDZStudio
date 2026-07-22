#!/bin/bash
# Runs every package's test suite; fails on the first red package.
# Usage: scripts/test-all.sh [--coverage]
set -euo pipefail
cd "$(dirname "$0")/.."

COVERAGE_FLAG=""
if [[ "${1:-}" == "--coverage" ]]; then
  COVERAGE_FLAG="--enable-code-coverage"
fi

PACKAGES=(
  Packages/USDCore
  Packages/DicyaninDesignSystem
  Packages/QuickLookKit
  Packages/RenderKit
  Packages/USDBridge
  Packages/MeshKit
  Packages/CaptureKit
  Packages/MechanismKit
  Packages/RigKit
  Packages/EditingKit
  Packages/ValidationKit
  Packages/ConversionKit
  Packages/ScriptingKit
  Packages/SculptKit
  Packages/SessionKit
  Packages/AgentMCP
  Packages/RenderKit
  Packages/ViewportKit
  Packages/EditorUI
  CLI
  Tools/EditorHarness
)

for pkg in "${PACKAGES[@]}"; do
  echo "──── swift test: $pkg"
  (cd "$pkg" && swift test $COVERAGE_FLAG)
done

echo "──── swift build: App"
(cd App && swift build)

echo "All packages green."
