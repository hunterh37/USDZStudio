# Testing & Coverage Specification

## Policy

**Coverage is a CI-enforced gate, not an aspiration.** Every PR runs the full suite with code coverage; the build fails if any module drops below its floor. Logic modules are held to 100%; rendering/UI modules are held to high floors plus mandatory non-line-coverage verification (snapshot, golden-image, UI tests) because line coverage is the wrong instrument there.

> **Enforcement status.** The floors below are the *targets*. They are live and enforced today for the six logic modules, DicyaninDesignSystem, CLI, and — as of Milestone 4 — **USDBridge**, which graduated from its 90% ratchet to its 95% spec floor once the bridge mini-corpus and real usd-core save-path tests landed (it measures 100% today). ViewportKit and EditorUI still run on **ratchet floors** (pinned at measured coverage, raised as the golden-image/snapshot/XCUITest harnesses land) rather than the targets here — 58% and 65% respectively (raised as #126 landed the golden-image ΔE comparator and the QuickLook render-parity models).
>
> **Gate integrity.** Every floor here is only as good as the measurement behind it. `_coverage_measure.py` matches report paths against each module's source tree case-insensitively on case-insensitive filesystems (macOS/Windows), because llvm records the on-disk casing while the caller's path inherits whatever casing it was invoked through; a case-sensitive comparison matched zero files and silently reported a vacuous 100% for **all thirteen modules**. Independently of that cause, a module measuring zero source files is now a hard failure — in `--report` mode too — rather than a pass: "measured nothing" must never render as "fully covered." A third integrity fix: the gate collects coverage with `--no-parallel`. Under swift-testing's default parallel execution, counters written from async tool pipelines were intermittently lost, so identical runs reported 90.5%/99.5%/100% for AgentMCP — a covered line group (e.g. its `PrimTree` collision loop) reading zero even though every test passed. This was not stale-profraw accumulation; the codecov directory holds a stable two files, overwritten each run. Serial collection made the measured number deterministic (0 drops in 80 runs vs ~4 in 50 parallel); the parallel speed win stays in `test-all.sh`, whose job is pass/fail, not measurement. The authoritative, machine-checked floors are the `MODULES` table in `scripts/coverage-gate.sh`; the gap to the targets below is tracked in ROADMAP Phase T. This note and that table change together.

## Per-Module Coverage Floors (enforced via xccov + CI script)

| Module | Floor | Primary test style |
|---|---|---|
| USDCore | **100%** | Pure unit tests (value types, protocols, prim-path math) |
| MeshKit | **100%** | Unit + property/fuzz corpus + golden meshes; gate live in `scripts/coverage-gate.sh` |
| CaptureKit | **100%** | Unit: pre-flight `validate` (monotonicity, boundary thresholds, every `CaptureIssue.isBlocking` branch), `plan` determinism, detail→session table exhaustive, golden `CapturePlan` JSON per detail — see `specs/capture-import.md` |
| MechanismKit | **100%** | Unit + fuzz corpus: joint schema validation, pivot-transform math, and the geometric invariants (axis fixed-point, rest==closed, geometry-in-place, prismatic displacement) — see `specs/articulation-mechanisms.md` |
| RigKit | **100%** | Unit + fuzz corpus: skeleton/pose/skin schema + FK, solver determinism & convergence (2-bone/CCD/FABRIK), constraints, auto-rig fit + weight solve, humanoid bone-identification goldens, retarget round-trip, motion-quality sub-metrics, and the self-validation gate contract — see `specs/animation-rigging.md` |
| EditingKit | **100%** | Unit: every command's execute/undo/redo/coalesce path |
| ValidationKit | **100%** | Unit: every rule × pass/fail/edge fixture, quick-fix round-trips |
| ConversionKit | **100%** (logic) | Unit + corpus integration (glTF-Sample-Models in CI) |
| ScriptingKit | **100%** (logic) | Unit + scripted-session integration tests |
| SculptKit | **100%** (logic) | Unit: spec round-trip, strict-quality gate, pass-lock ordering + gate, detail mapping, build-plan generation |
| SessionKit | **100%** (logic) | Unit: envelope/view-state Codable round-trips, migration/incompatible-version discard, corrupt/absent persistence, WAL recovery-plan derivation, source bookmark/fingerprint change detection |
| AgentMCP | **100%** (logic) | Unit: JSON-RPC dispatch, every tool × valid/invalid params, session diff/undo semantics; process seams (stdio loop, usdrecord, Python) injected + excluded |
| USDBridge | **95%** | Golden-file integration (real usd-core, real assets) over the committed mini-corpus + `StageSaver` save-path round-trips; the uncovered remainder is interpreter-crash handlers, each annotated |
| QuickLookKit | **100%** (logic) | Unit: render-plan resolution, usdrecord location, temp-path derivation; process spawn lives in the thin .appex (App/QuickLookShared), excluded from the logic gate |
| RenderKit | **100%** (logic) | Unit: render-stage parsing (diffuse/binding/camera) + renderer-selection policy; the SceneKit/Metal + usdrecord render bodies are process/GPU seams, `coverage:disable`-annotated. Shared by both MCP hosts (issue #109) |
| DicyaninDesignSystem | **95%** + snapshots | Unit for logic (numeric parsing, scrub math) + snapshot tests for every component state in the preview catalog |
| ViewportKit | **90%** + golden images | Unit for camera math/selection/diffing; golden-image rendering tests for view modes; GPU submission glue excluded with annotation |
| EditorUI | **90%** + snapshots + XCUITest | Snapshot per panel state; XCUITest flows for document lifecycle, editing, export |
| App / CLI | **95%** | CLI: every subcommand × exit-code matrix; App target is <200 lines of wiring by design |

### Exclusion discipline

- No blanket file exclusions. Every excluded region requires an inline `// coverage:disable — <reason>` annotation; CI extracts these into a reviewed manifest. New annotations require a second reviewer.
- `#if DEBUG` preview/dev-only code is compiled out of coverage builds, not excluded.

## Test Layers

1. **Unit** (fast, no I/O): all logic modules. Deterministic, parallel, < 60s total.
2. **Bridge integration:** real embedded Python + usd-core against a committed mini-corpus. Lives at `Packages/USDBridge/Tests/USDBridgeTests/Fixtures/Corpus` and covers variants, skels, animations, packaged `.usdz`, and malformed input; `RealCorpusTests` asserts golden structure per fixture and skips cleanly when no interpreter has `pxr` (CI always has one).
3. **Conversion corpus:** Khronos glTF-Sample-Models + our fixture set; asserts success rate, then re-opens and validates every output (ComplianceChecker) — conversion output is itself tested, not just conversion code.
4. **Round-trip invariants** (blocking CI job `roundtrip`, `scripts/roundtrip-gate.sh`, driven by `openusdz roundtrip`). Three invariants per corpus file:
   - **Model idempotence** — `open(F) == open(save(open(F)))`. Checked on the value-typed `StageSnapshot`, so it covers every prim, attribute, relationship, variant set, and piece of stage metadata the editor models. `sourceURL` is normalized out (it is file identity, not content).
   - **Edit/undo neutrality** — `open(F) == open(save(undoAll(edit(open(F)))))`. Runs real commands through a journaled `CommandStack`, exercising the same inverse-capture path the crash journal depends on.
   - **Strict text diff** (`--strict`) — flattened USD text compared via `Resources/Python/usd_roundtrip.py` (a normalizing `usddiff` stand-in; usd-core ships `usddiff` only as a wrapper around an external diff tool).

   Each file's expected outcome lives in the gate's `EXPECTATIONS` table, and the gate is red when reality disagrees **in either direction** — a declared-passing invariant that starts failing is a regression; a declared-failing one that starts passing means the table must be tightened. Same ratchet discipline as `coverage-gate.sh`: a known gap can neither widen quietly nor be closed without being recorded.

   Two gaps are declared today, both pre-existing and outside Milestone 4 scope: `USDASerializer` emits no `variantSet` blocks (variant sets are dropped on save — Phase 12), and attributes the bridge surfaces as `.unsupported` — a purely time-sampled channel has no default-time value — are written as an "omitted" comment, so their values are dropped on save (Phase 10). These are why `strict` is `no` across the corpus today: re-serializing also materializes computed attributes (`purpose`, `visibility`), so flattened text is not yet byte-equivalent.
5. **Crash-journal recovery:** the write-ahead log is exercised end-to-end in `EditingKitTests/CrashRecoveryTests` — the WAL is written through the real `CommandStack` + `FileCommandJournal` (`fsync` per append), a real child process is terminated with `SIGKILL` so no cleanup runs, and recovery rebuilds stage content plus both undo and redo stacks from the bytes on disk alone. A record torn in half by the kill is discarded without losing the complete records before it.
6. **Property-based tests** (swift-testing + custom generators): prim-path operations, transform compose/decompose, name sanitization — fuzzed inputs, invariant assertions.
7. **Golden-image rendering:** offscreen viewport renders vs. reference PNGs, perceptual diff (ΔE threshold), per debug-view-mode and per IBL preset. Re-baselining requires PR review of image diffs.
8. **Snapshot UI:** every DesignSystem component state; every inspector/outliner panel configuration.
9. **XCUITest smoke flows:** open → select part → move → hide → export → re-open exported file; batch convert; console script run. Run on CI per PR (headless), full matrix nightly.
10. **CLI matrix:** every subcommand × {valid input, invalid input, warning input} × {default, --json, --strict}; exit codes asserted.
11. **E2E feature flows** (blocking CI job `e2e`, `scripts/e2e-gate.sh`, spec `specs/e2e-testing.md`). Whole user journeys driven through the real product seam — the `openusdz mcp` JSON-RPC server (`--no-relay`, headless) against the real embedded usd-core bridge — one scenario per major feature: author-from-scratch (create geometry → bind material → validate → save), edit/undo/redo neutrality, variant selection, and validation + ARKit compliance gating. Scenarios are authored as data (`Tests/E2E/scenarios/*.json`), asserted on the tools' structured results, and governed by the same bidirectional `EXPECTATIONS` ratchet as the round-trip gate: a declared-pass flow that fails is a regression, a declared-fail flow that starts passing forces the table to tighten. This layer asserts *cross-feature* correctness — that composing the feature tools end to end produces the right scene, verdicts, and history — which per-module line coverage cannot see, so it is a flow gate, not a coverage-floored module. Each scenario runs against a throwaway copy of the fixtures so a `save` step never mutates committed files. New major features add a scenario here as their definition-of-done.

## CI Pipeline (GitHub Actions, macOS runner)

```
lint (SwiftLint + dependency-lint) → build → unit (coverage gate per module)
→ bridge+conversion integration → round-trip + e2e flow gates → golden/snapshot → XCUITest smoke → coverage report comment on PR
```

- Coverage delta posted as a PR comment; any module below floor = red X, no override label exists on purpose.
- Nightly: full corpus, performance benchmarks (1M-tri orbit fps, open-time), memory-leak pass (`leaks` on scripted session).

## Definition of Done (every PR)

A feature PR must contain: tests for every new code path (including error paths), fixture assets if it touches file handling, a golden/snapshot update if it touches pixels, and zero new coverage annotations without justification. This is in CONTRIBUTING.md and enforced in review — the coverage gate makes it structural rather than cultural.
