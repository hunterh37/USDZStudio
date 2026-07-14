#!/bin/bash
# Fetches a relocatable Python runtime with usd-core into
# Resources/Python/runtime/ (never committed — see PRD risks table).
# Phase 0 implementation: a local venv against any system Python 3.9+.
# The python.org universal2 framework build replaces this in Phase 1 packaging.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME_DIR="Resources/Python/runtime"
PYTHON="${DICYANIN_PYTHON:-$(command -v python3)}"

if [[ -z "$PYTHON" ]]; then
  echo "error: no python3 on PATH; install Python 3.9+ or set DICYANIN_PYTHON" >&2
  exit 1
fi

echo "Using base interpreter: $PYTHON"
"$PYTHON" -m venv "$RUNTIME_DIR"
"$RUNTIME_DIR/bin/pip" install --quiet --upgrade pip
"$RUNTIME_DIR/bin/pip" install --quiet usd-core

# Smoke test (Phase 0 roadmap: `import pxr` must succeed).
"$RUNTIME_DIR/bin/python3" -c "import pxr; from pxr import Usd; print('usd-core OK:', Usd.GetVersion())"
echo "Python runtime ready at $RUNTIME_DIR"
