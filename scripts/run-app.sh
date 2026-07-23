#!/bin/bash
# Builds and launches the Dicyanin USDZ Editor as a real .app bundle.
# Generates the Xcode project if needed, builds with xcodebuild, then opens
# the resulting bundle. Optionally opens a model file on launch.
# Usage: scripts/run-app.sh [path/to/model.usdz]
set -euo pipefail
cd "$(dirname "$0")/.."

# Regenerate the (git-ignored) Xcode project when it is missing OR stale — i.e.
# when project.yml or the generator script is newer than the generated project.
# A stale project left over from another branch is missing newly-added targets
# (e.g. RenderKit) and fails the build with a confusing linker error (#146).
# XcodeGen is fast and deterministic, so regenerating on any input change is safe.
PROJ=USDZStudio.xcodeproj
if [[ ! -d "$PROJ" ]] \
  || [[ project.yml -nt "$PROJ" ]] \
  || [[ scripts/generate-xcodeproj.sh -nt "$PROJ" ]]; then
  scripts/generate-xcodeproj.sh
fi

CONFIG="${CONFIG:-Debug}"
DERIVED="$(pwd)/.build/xcode"

echo "──── xcodebuild: USDZStudio ($CONFIG)"
xcodebuild \
  -project USDZStudio.xcodeproj \
  -scheme USDZStudio \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build | tail -5

APP="$DERIVED/Build/Products/$CONFIG/USDZStudio.app"
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
