#!/bin/bash
# Enforces the one-directional dependency rules from specs/architecture.md by
# scanning `import` statements in each module's sources.
set -euo pipefail
cd "$(dirname "$0")/.."

FAILURES=0

# allowed_imports <module-source-dir> <space-separated allowlist of internal modules>
check() {
  local dir="$1"; shift
  local allowed=" $* "
  local internal="USDCore USDBridge ConversionKit ViewportKit EditingKit ValidationKit ScriptingKit EditorUI DicyaninDesignSystem"
  while IFS=: read -r file line; do
    local mod
    mod=$(echo "$line" | sed -E 's/^[[:space:]]*(@testable )?import +([A-Za-z_][A-Za-z0-9_]*).*/\2/')
    for m in $internal; do
      if [[ "$mod" == "$m" && "$allowed" != *" $m "* ]]; then
        echo "DEPENDENCY VIOLATION: $file imports $m (allowed: ${allowed})"
        FAILURES=$((FAILURES+1))
      fi
    done
    # USDCore must stay free of UI/GPU/Python frameworks.
    if [[ "$dir" == Packages/USDCore/Sources* ]]; then
      case "$mod" in
        SwiftUI|AppKit|RealityKit|Metal|PythonKit)
          echo "DEPENDENCY VIOLATION: USDCore imports forbidden framework $mod ($file)"
          FAILURES=$((FAILURES+1));;
      esac
    fi
  done < <(grep -rn -E '^[[:space:]]*(@testable )?import ' "$dir" 2>/dev/null || true)
}

check Packages/USDCore/Sources                ""
check Packages/USDBridge/Sources             "USDCore"
check Packages/ConversionKit/Sources         "USDCore"
check Packages/ViewportKit/Sources           "USDCore"
check Packages/EditingKit/Sources            "USDCore ValidationKit"  # QuickFixRegistry maps Diagnostics -> undoable commands
check Packages/ValidationKit/Sources         "USDCore"
check Packages/ScriptingKit/Sources          "USDCore"
check Packages/DicyaninDesignSystem/Sources  ""
check Packages/EditorUI/Sources              "USDCore USDBridge ConversionKit ViewportKit EditingKit ValidationKit ScriptingKit DicyaninDesignSystem"
check App/Sources                            "USDCore USDBridge ConversionKit ViewportKit EditingKit ValidationKit ScriptingKit EditorUI DicyaninDesignSystem"
check CLI/Sources                            "USDCore USDBridge ConversionKit ValidationKit ScriptingKit EditingKit"  # never EditorUI/DesignSystem

if [[ $FAILURES -gt 0 ]]; then
  echo "dependency-lint: $FAILURES violation(s)"
  exit 1
fi
echo "dependency-lint: OK"
