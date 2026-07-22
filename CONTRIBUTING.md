# Contributing to USDZ Studio

Thanks for your interest in contributing! This document covers the workflow and expectations for changes.

## Workflow

`main` is protected: all changes land via pull request with green CI. Direct pushes, force pushes, and branch deletion are blocked.

1. Fork the repo (or create a branch if you have write access — never commit to `main` directly).
2. Create a topic branch: `git checkout -b feat/my-change`.
3. Make your changes, keeping commits focused.
4. Run the checks below locally.
5. Open a PR against `main` and fill in the template. Resolve all review threads before merge.

PRs are squash-merged by default, with the PR title becoming the commit title — use a descriptive, conventional-commit-style title (e.g. `feat(viewport): ...`, `fix(meshkit): ...`, `docs: ...`).

## Local checks (mirrors CI)

```sh
bash scripts/dependency-lint.sh      # dependency rules
bash scripts/module-governance.sh    # module governance gate
bash scripts/fetch-python-runtime.sh # one-time: usd-core runtime
bash scripts/test-all.sh --coverage  # all package tests
bash scripts/coverage-gate.sh        # MeshKit 100% coverage floor + fuzz corpus
```

CI runs on macOS 15 with Xcode 16.4. The `lint` and `test` jobs are required status checks; a PR cannot merge until both pass.

## Testing expectations

- New behavior needs tests. MeshKit enforces a 100% line-coverage floor.
- Fuzz-sensitive changes in MeshKit should extend the committed fuzz corpus (`FuzzCorpus.swift`) where relevant.
- See `specs/testing.md` for per-module coverage policy.

## Project structure

- `App/` — the macOS app (generated `.xcodeproj` via XcodeGen; edit `project.yml`, then `bash scripts/generate-xcodeproj.sh`)
- `CLI/` — the `openusdz` command-line tool
- `Packages/` — Swift packages (MeshKit, etc.)
- `specs/` — design and testing specs; `ROADMAP.md` tracks phases

## Questions / bugs

Open a GitHub issue. For larger features, please open an issue to discuss the design before writing code.
