# QuickLook Thumbnail & Preview — spec

Finder-level QuickLook integration for USD files (`.usd`, `.usda`, `.usdc`, `.usdz`):
thumbnails in Finder/Spotlight and a Space-bar preview pane, provided by two
macOS app extensions (`.appex`) embedded in the host app. This is distinct from
the CLI `usdrecord` `thumbnail` subcommand but reuses the same single-frame,
auto-framed `usdrecord` render pipeline.

## Modules

- **`QuickLookKit`** (`Packages/QuickLookKit`) — pure Swift, zero internal
  dependencies. Holds the reusable, filesystem-agnostic render-plan logic:
  - `USDAThumbnailRenderer.supportedExtensions` / `canPreview(_:)`
  - `locateUsdrecord(environment:locatePython:fileExists:)` — env override
    (`DICYANIN_USDRECORD`) → `usdrecord` beside the located Python interpreter.
  - `renderPlan(source:outputPath:maximumPixelSize:usdrecord:)` — builds the
    exact `usdrecord --imageWidth N <source> <output>` invocation.
  - `temporaryOutputPath(for:token:temporaryDirectory:)`.

  100% line-coverage floor (`specs/testing.md`). All side effects (spawning the
  process, decoding the PNG) live outside the package.

- **`App/QuickLookShared/QuickLookRenderService.swift`** — thin glue compiled into
  both extensions: locates the Python runtime bundled in the host `.app`, spawns
  `usdrecord`, and loads the rendered PNG as an `NSImage`.

- **`App/QuickLookThumbnail`** — `QLThumbnailProvider` (`ThumbnailProvider`),
  extension point `com.apple.quicklook.thumbnail`.

- **`App/QuickLookPreview`** — `QLPreviewingController`
  (`PreviewViewController`), extension point `com.apple.quicklook.preview`.

## Registration

Both extensions declare `QLSupportedContentTypes` of
`com.pixar.universal-scene-description` (`.usd/.usda/.usdc`) and
`com.pixar.universal-scene-description-mobile` (`.usdz`). They are wired into the
host app in `project.yml` as embedded `app-extension` targets
(`Contents/PlugIns/*.appex`); regenerate the project with
`bash scripts/generate-xcodeproj.sh`.

## Distribution note

The host app is unsigned and un-sandboxed (`specs/architecture.md` §App
Distribution), so the embedded extensions may spawn `usdrecord` from the bundled
runtime without sandbox entitlements. A sandboxed/App-Store distribution would
instead require an in-process render path.
