#!/bin/bash
# Fetches the FBX2glTF binary (facebookincubator/FBX2glTF) into
# Resources/Tools/FBX2glTF (never committed). FBX2glTF converts .fbx → .glb,
# which ConversionKit's FBXImporter then feeds to the native GLTF importer.
#
# The download is CHECKSUM-VERIFIED: the SHA-256 below is pinned to the
# release version in FBX2GLTF_VERSION. When bumping the version you MUST
# update FBX2GLTF_SHA256 to the new asset's digest, or this script will
# refuse the download.
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Pinned release (PLACEHOLDER — update version + digest together) ---------
# The sandbox cannot reach the network; these values are placeholders that
# demonstrate the verify flow. Replace with a real release asset + its
# published SHA-256 when wiring this up for distribution.
FBX2GLTF_VERSION="v0.9.7"
FBX2GLTF_URL="https://github.com/facebookincubator/FBX2glTF/releases/download/${FBX2GLTF_VERSION}/FBX2glTF-macos-x86_64"
FBX2GLTF_SHA256="0000000000000000000000000000000000000000000000000000000000000000"

TOOLS_DIR="Resources/Tools"
BINARY_PATH="$TOOLS_DIR/FBX2glTF"

mkdir -p "$TOOLS_DIR"

echo "Downloading FBX2glTF ${FBX2GLTF_VERSION}…"
curl -fL --retry 3 -o "$BINARY_PATH" "$FBX2GLTF_URL"

echo "Verifying SHA-256…"
COMPUTED="$(shasum -a 256 "$BINARY_PATH" | awk '{print $1}')"
if [[ "$COMPUTED" != "$FBX2GLTF_SHA256" ]]; then
  echo "error: checksum mismatch for $BINARY_PATH" >&2
  echo "  expected: $FBX2GLTF_SHA256" >&2
  echo "  actual:   $COMPUTED" >&2
  echo "  (bumping the version? update FBX2GLTF_SHA256 to match.)" >&2
  rm -f "$BINARY_PATH"
  exit 1
fi

chmod +x "$BINARY_PATH"
echo "FBX2glTF ready at $BINARY_PATH (set FBX2GLTF_PATH to override)."
