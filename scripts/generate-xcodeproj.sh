#!/bin/bash
# Generates OpenUSDZEditor.xcodeproj from project.yml via XcodeGen.
# The .xcodeproj is git-ignored; project.yml is the checked-in source of truth.
# Usage: scripts/generate-xcodeproj.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with:  brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --spec project.yml
echo "Generated OpenUSDZEditor.xcodeproj — open it with:  open OpenUSDZEditor.xcodeproj"
