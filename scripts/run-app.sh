#!/bin/bash
# Builds and launches the Dicyanin USDZ Editor as a real .app bundle.
# Generates the Xcode project if needed, builds with xcodebuild, then opens
# the resulting bundle. Optionally opens a model file on launch.
# Usage: scripts/run-app.sh [path/to/model.usdz]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -d OpenUSDZEditor.xcodeproj ]]; then
  scripts/generate-xcodeproj.sh
fi

CONFIG="${CONFIG:-Debug}"
DERIVED="$(pwd)/.build/xcode"

echo "──── xcodebuild: OpenUSDZEditor ($CONFIG)"
xcodebuild \
  -project OpenUSDZEditor.xcodeproj \
  -scheme OpenUSDZEditor \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build | tail -5

APP="$DERIVED/Build/Products/$CONFIG/OpenUSDZEditor.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build succeeded but app bundle not found at $APP" >&2
  exit 1
fi

echo "──── launching $APP"
if [[ $# -ge 1 ]]; then
  open -a "$APP" "$1"
else
  open "$APP"
fi
