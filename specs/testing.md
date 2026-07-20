# Testing & Coverage Specification

## Policy

**Coverage is a CI-enforced gate, not an aspiration.** Every PR runs the full suite with code coverage; the build fails if any module drops below its floor. Logic modules are held to 100%; rendering/UI modules are held to high floors plus mandatory non-line-coverage verification (snapshot, golden-image, UI tests) because line coverage is the wrong instrument there.

> **Enforcement status.** The floors below are the *targets*. They are live and enforced today for the six logic modules, DicyaninDesignSystem, and CLI. USDBridge, ViewportKit, and EditorUI currently run on **ratchet floors** (pinned at measured coverage, raised as the golden-image/snapshot/XCUITest harnesses land) rather than the targets here. The authoritative, machine-checked floors are the `MODULES` table in `scripts/coverage-gate.sh`; the gap to the targets below is tracked in ROADMAP Phase T. This note and that table change together.

## Per-Module Coverage Floors (enforced via xccov + CI script)

| Module | Floor | Primary test style |
|---|---|---|
| USDCore | **100%** | Pure unit tests (value types, protocols, prim-path math) |
| MeshKit | **100%** | Unit + property/fuzz corpus + golden meshes; gate live in `scripts/coverage-gate.sh` |
| EditingKit | **100%** | Unit: every command's execute/undo/redo/coalesce path |
| ValidationKit | **100%** | Unit: every rule × pass/fail/edge fixture, quick-fix round-trips |
| ConversionKit | **100%** (logic) | Unit + corpus integration (glTF-Sample-Models in CI) |
| ScriptingKit | **100%** (logic) | Unit + scripted-session integration tests |
| AgentMCP | **100%** (logic) | Unit: JSON-RPC dispatch, every tool × valid/invalid params, session diff/undo semantics; process seams (stdio loop, usdrecord, Python) injected + excluded |
| USDBridge | **95%** | Golden-file integration (real usd-core, real assets); the uncovered remainder is interpreter-crash handlers, each annotated |
| QuickLookKit | **100%** (logic) | Unit: render-plan resolution, usdrecord location, temp-path derivation; process spawn lives in the thin .appex (App/QuickLookShared), excluded from the logic gate |
| DicyaninDesignSystem | **95%** + snapshots | Unit for logic (numeric parsing, scrub math) + snapshot tests for every component state in the preview catalog |
| ViewportKit | **90%** + golden images | Unit for camera math/selection/diffing; golden-image rendering tests for view modes; GPU submission glue excluded with annotation |
| EditorUI | **90%** + snapshots + XCUITest | Snapshot per panel state; XCUITest flows for document lifecycle, editing, export |
| App / CLI | **95%** | CLI: every subcommand × exit-code matrix; App target is <200 lines of wiring by design |

### Exclusion discipline

- No blanket file exclusions. Every excluded region requires an inline `// coverage:disable — <reason>` annotation; CI extracts these into a reviewed manifest. New annotations require a second reviewer.
- `#if DEBUG` preview/dev-only code is compiled out of coverage builds, not excluded.

## Test Layers

1. **Unit** (fast, no I/O): all logic modules. Deterministic, parallel, < 60s total.
2. **Bridge integration:** real embedded Python + usd-core against a committed mini-corpus (20 hand-built usda/usdz fixtures covering variants, skels, animations, exotic schemas, malformed files).
3. **Conversion corpus:** Khronos glTF-Sample-Models + our fixture set; asserts success rate, then re-opens and validates every output (ComplianceChecker) — conversion output is itself tested, not just conversion code.
4. **Round-trip invariants:** open → save → `usddiff` clean, for every corpus file. Open → edit → undo-all → save → diff clean.
5. **Property-based tests** (swift-testing + custom generators): prim-path operations, transform compose/decompose, name sanitization — fuzzed inputs, invariant assertions.
6. **Golden-image rendering:** offscreen viewport renders vs. reference PNGs, perceptual diff (ΔE threshold), per debug-view-mode and per IBL preset. Re-baselining requires PR review of image diffs.
7. **Snapshot UI:** every DesignSystem component state; every inspector/outliner panel configuration.
8. **XCUITest smoke flows:** open → select part → move → hide → export → re-open exported file; batch convert; console script run. Run on CI per PR (headless), full matrix nightly.
9. **CLI matrix:** every subcommand × {valid input, invalid input, warning input} × {default, --json, --strict}; exit codes asserted.

## CI Pipeline (GitHub Actions, macOS runner)

```
lint (SwiftLint + dependency-lint) → build → unit (coverage gate per module)
→ bridge+conversion integration → golden/snapshot → XCUITest smoke → coverage report comment on PR
```

- Coverage delta posted as a PR comment; any module below floor = red X, no override label exists on purpose.
- Nightly: full corpus, performance benchmarks (1M-tri orbit fps, open-time), memory-leak pass (`leaks` on scripted session).

## Definition of Done (every PR)

A feature PR must contain: tests for every new code path (including error paths), fixture assets if it touches file handling, a golden/snapshot update if it touches pixels, and zero new coverage annotations without justification. This is in CONTRIBUTING.md and enforced in review — the coverage gate makes it structural rather than cultural.
