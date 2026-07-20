#!/bin/bash
# Enforces the one-directional dependency rules from specs/architecture.md.
#
# Self-maintaining by design:
#   1. The set of internal modules is DISCOVERED from Packages/ (plus App, CLI,
#      Tools/*) — never hand-listed. A new package with no policy entry below is
#      itself a lint failure, so modules cannot silently escape governance.
#   2. Import statements in every module's Sources are checked against the
#      policy allowlist (imports must be a subset of the policy).
#   3. Each Package.swift manifest's `.package(path:)` internal dependencies are
#      also checked against the policy, catching undeclared coupling before any
#      import exists.
#   4. Framework bans: USDCore and MeshKit stay pure Swift (no UI/GPU/Python).
set -euo pipefail
cd "$(dirname "$0")/.."

FAILURES=0
fail() { echo "DEPENDENCY VIOLATION: $1"; FAILURES=$((FAILURES+1)); }

# ── Discover internal modules (self-maintaining: derived from the filesystem).
INTERNAL_MODULES=""
for d in Packages/*/; do
  INTERNAL_MODULES="$INTERNAL_MODULES $(basename "$d")"
done

# ── Policy: the architectural contract (specs/architecture.md §Dependency Rules).
# policy_for <module-key> → space-separated allowlist of internal modules it may use.
# An entry must exist for every discovered package and every app-level target.
policy_for() {
  case "$1" in
    USDCore)              echo "" ;;
    MeshKit)              echo "" ;;                    # pure Swift, zero deps (specs/mesh-editing.md)
    DicyaninDesignSystem) echo "" ;;
    QuickLookKit)         echo "" ;;                    # pure Swift render-plan logic for the QuickLook .appex (specs/quicklook.md)
    USDBridge)            echo "USDCore" ;;
    ConversionKit)        echo "USDCore" ;;
    ValidationKit)        echo "USDCore" ;;
    ScriptingKit)         echo "USDCore" ;;
    ViewportKit)          echo "USDCore MeshKit" ;;     # component-overlay rendering (specs/mesh-editing.md)
    EditingKit)           echo "USDCore ValidationKit MeshKit" ;;  # QuickFixRegistry maps Diagnostics -> undoable commands
    AgentMCP)             echo "USDCore USDBridge EditingKit ValidationKit ConversionKit ScriptingKit MeshKit" ;;  # MCP adapter over the kits (docs/AGENT_MCP_PLAN.md); never EditorUI
    EditorUI)             echo "USDCore USDBridge ConversionKit ViewportKit EditingKit ValidationKit ScriptingKit DicyaninDesignSystem MeshKit" ;;
    App)                  echo "USDCore USDBridge ConversionKit ViewportKit EditingKit ValidationKit ScriptingKit EditorUI DicyaninDesignSystem MeshKit" ;;
    CLI)                  echo "USDCore USDBridge ConversionKit ValidationKit ScriptingKit EditingKit MeshKit AgentMCP" ;;  # never EditorUI/DesignSystem
    EditorHarness)        echo "USDCore USDBridge EditingKit MeshKit EditorUI" ;;  # dev tool: drives the real UI
    *)                    return 1 ;;
  esac
}

# ── Targets to check: <module-key>:<sources-dir>:<manifest>
TARGETS=""
for d in Packages/*/; do
  name=$(basename "$d")
  TARGETS="$TARGETS $name:${d}Sources:${d}Package.swift"
done
TARGETS="$TARGETS App:App/Sources:App/Package.swift"
TARGETS="$TARGETS CLI:CLI/Sources:CLI/Package.swift"
TARGETS="$TARGETS EditorHarness:Tools/EditorHarness/Sources:Tools/EditorHarness/Package.swift"

for entry in $TARGETS; do
  key="${entry%%:*}"; rest="${entry#*:}"
  src="${rest%%:*}"; manifest="${rest#*:}"

  if ! allowed=$(policy_for "$key"); then
    fail "$key has no policy entry in scripts/dependency-lint.sh — every module must be governed (add a policy entry AND update specs/architecture.md)"
    continue
  fi
  allowed=" $allowed "

  # 2. Import statements ⊆ policy.
  while IFS=: read -r file _ line; do
    [[ -z "$file" ]] && continue
    mod=$(echo "$line" | sed -E 's/^[[:space:]]*(@testable )?import +([A-Za-z_][A-Za-z0-9_]*).*/\2/')
    for m in $INTERNAL_MODULES; do
      [[ "$m" == "$key" ]] && continue
      if [[ "$mod" == "$m" && "$allowed" != *" $m "* ]]; then
        fail "$file imports $m (allowed for $key:${allowed})"
      fi
    done
  done < <(grep -rn -E '^[[:space:]]*(@testable )?import ' "$src" 2>/dev/null || true)

  # 3. Manifest internal deps ⊆ policy.
  if [[ -f "$manifest" ]]; then
    while read -r dep; do
      [[ -z "$dep" ]] && continue
      is_internal=false
      for m in $INTERNAL_MODULES; do [[ "$dep" == "$m" ]] && is_internal=true; done
      if $is_internal && [[ "$allowed" != *" $dep "* ]]; then
        fail "$manifest declares dependency on $dep (allowed for $key:${allowed})"
      fi
    done < <(grep -oE '\.package\(path: *"[^"]*"' "$manifest" | sed -E 's|.*/([A-Za-z_][A-Za-z0-9_]*)"$|\1|')
  fi

  # 4. Framework bans: pure-Swift modules stay free of UI/GPU/Python frameworks.
  if [[ "$key" == "USDCore" || "$key" == "MeshKit" ]]; then
    while IFS=: read -r file _ line; do
      [[ -z "$file" ]] && continue
      mod=$(echo "$line" | sed -E 's/^[[:space:]]*(@testable )?import +([A-Za-z_][A-Za-z0-9_]*).*/\2/')
      case "$mod" in
        SwiftUI|AppKit|UIKit|RealityKit|Metal|MetalKit|ModelIO|PythonKit)
          fail "$key imports forbidden framework $mod ($file) — $key is a pure Swift module" ;;
      esac
    done < <(grep -rn -E '^[[:space:]]*(@testable )?import ' "$src" 2>/dev/null || true)
  fi
done

if [[ $FAILURES -gt 0 ]]; then
  echo "dependency-lint: $FAILURES violation(s)"
  exit 1
fi
echo "dependency-lint: OK ($(echo $INTERNAL_MODULES | wc -w | tr -d ' ') internal modules governed)"
