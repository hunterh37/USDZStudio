# Building OpenUSDZEditor from source

OpenUSDZEditor is an open-source native macOS app. There are no signed installers;
you either download an unsigned build from [Releases](https://github.com/hunterh37/OpenUSDZEditor/releases)
or build it yourself. This guide covers both.

## Requirements

- macOS 14 (Sonoma) or later — Apple Silicon is the primary target, Intel is best-effort.
- Xcode 16 or later / Swift 6.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the
  `.xcodeproj` is generated from `project.yml`, which is the checked-in source of truth.

The Swift packages under `Packages/` and the `openusdz` CLI build with plain
`swift build` / `swift test` and need nothing beyond the toolchain. The editor
*shell* additionally needs a real `.app` bundle (Info.plist, document-type
registration, embedded Python), which is why it goes through Xcode.

## Quick start

```sh
git clone https://github.com/hunterh37/OpenUSDZEditor.git
cd OpenUSDZEditor

# One-time: fetch the embedded Python / usd-core runtime the app bundles.
bash scripts/fetch-python-runtime.sh

# Run every package's tests plus the app build.
bash scripts/test-all.sh

# Build the real .app bundle and launch it (optionally opening a model).
bash scripts/run-app.sh [model.usdz]
```

Without a Python runtime that can `import pxr`, the app still launches but
degrades gracefully to a viewer-only state (see
[`specs/usd-bridge.md`](../specs/usd-bridge.md)). The `fetch-python-runtime.sh`
step above installs that runtime so you get the full editor.

## Producing a release build

To build the same unsigned, distributable artifact the CI Release workflow
uploads:

```sh
bash scripts/build-release.sh        # writes dist/OpenUSDZEditor-macos.zip
```

This builds the `Release` configuration with signing disabled and packages the
bundle with `ditto` (which preserves the framework symlinks a plain `zip`
would corrupt). The script prints the artifact's SHA-256 so you can compare it
against a downloaded build.

## Running an unsigned build

Because these builds are **not code-signed or notarized**, Gatekeeper will
quarantine them on first launch. After unzipping, clear the quarantine
attribute once:

```sh
xattr -dr com.apple.quarantine OpenUSDZEditor.app
```

Then open the app normally. (Right-click ▸ Open also works, but the `xattr`
approach is reliable across macOS versions.) If you would rather not trust a
prebuilt binary, build from source with the steps above — the result is
identical.

## The Xcode project

`project.yml` is the source of truth; the generated `OpenUSDZEditor.xcodeproj`
is git-ignored. Regenerate it after editing `project.yml`:

```sh
bash scripts/generate-xcodeproj.sh   # project.yml -> OpenUSDZEditor.xcodeproj
open OpenUSDZEditor.xcodeproj
```

For a fast, unbundled dev loop, `cd App && swift run` still works — it resolves
the bundled Python scripts by walking up from the repo root rather than from
app resources.
