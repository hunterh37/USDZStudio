#!/bin/bash
# Builds an UNSIGNED Release .app bundle and packages it as a distributable zip.
#
# This is the artifact the GitHub Releases workflow uploads and that
# build-from-source users produce locally (docs/BUILD.md). It is deliberately
# unsigned: the project ships open-source with no Developer ID, so downloaders
# clear Gatekeeper themselves (see docs/BUILD.md § Running an unsigned build).
#
# Usage: scripts/build-release.sh [output-dir]
#   output-dir defaults to ./dist
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"
CONFIG="Release"
DERIVED="$(pwd)/.build/xcode-release"

# The Python/usd-core runtime is bundled into the app's Resources; fetch it so
# the shipped build is a full editor, not a viewer-only degraded shell.
bash scripts/fetch-python-runtime.sh

if [[ ! -d OpenUSDZEditor.xcodeproj ]]; then
  scripts/generate-xcodeproj.sh
fi

echo "──── xcodebuild: OpenUSDZEditor ($CONFIG, unsigned)"
xcodebuild \
  -project OpenUSDZEditor.xcodeproj \
  -scheme OpenUSDZEditor \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_STYLE=Manual \
  build | tail -8

APP="$DERIVED/Build/Products/$CONFIG/OpenUSDZEditor.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build succeeded but app bundle not found at $APP" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/OpenUSDZEditor-macos.zip"
rm -f "$ZIP"
# ditto preserves the bundle's symlinks/permissions (a plain zip corrupts the
# framework layout).
ditto -c -k --keepParent "$APP" "$ZIP"

echo "──── packaged $ZIP"
shasum -a 256 "$ZIP"
