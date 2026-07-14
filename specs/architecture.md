# Architecture Specification

## Goals

Modularity is the product strategy: an open-source contributor should be able to add an importer, an inspector panel, or a validation rule without understanding the whole app. We enforce this with Swift Package Manager module boundaries and one-directional dependencies.

## Workspace Layout

```
DicyaninUSDZEditor/
├── App/                          # Thin app target (SwiftUI lifecycle, DI wiring)
├── Packages/
│   ├── USDCore/                  # Pure Swift USD stage model (no UI, no Python)
│   ├── USDBridge/                # Python/usd-core interop (only module touching Python)
│   ├── ConversionKit/            # Importers, pipeline stages, batch engine
│   ├── ViewportKit/              # RealityKit viewport, camera, gizmos, IBL
│   ├── EditingKit/               # Command layer, undo, stage mutations
│   ├── ValidationKit/            # Rules engine, usdchecker adapter
│   ├── ScriptingKit/             # Python console, script library, CLI core
│   ├── EditorUI/                 # Panels: outliner, inspector, console, toolbar
│   └── DicyaninDesignSystem/     # Tokens, colors, typography, reusable controls
├── CLI/                          # dicyanin-usdz command-line target (links kits, no UI)
├── Resources/Python/             # Bundled Python runtime + usd-core wheel + scripts
├── Tests/                        # Per-package tests + integration corpus tests
└── specs/
```

## Dependency Rules (enforced in CI via a dependency-lint script)

```
App ─▶ EditorUI ─▶ {ViewportKit, EditingKit, ConversionKit, ValidationKit, ScriptingKit} ─▶ USDCore
USDBridge ─▶ USDCore          (bridge implements USDCore protocols)
DicyaninDesignSystem ◀─ EditorUI only
CLI ─▶ kits (never EditorUI)
```

- **USDCore never imports Python, RealityKit, or SwiftUI.** It defines `USDStageProtocol`, `Prim`, `Attribute`, `MaterialDescription`, `VariantSet` as value/reference types plus protocols.
- **USDBridge is the only module that links the embedded Python.** It provides the concrete `USDStage` implementation by calling `usd-core`. Swapping it later for a native C++ OpenUSD build changes one module.
- **ViewportKit consumes USDCore models, never USDBridge directly.** RealityKit entities are a derived projection rebuilt from stage-change notifications.

## Core Data Flow

```
 .usdz file
    │  open
    ▼
USDBridge (usd-core via Python) ──▶ USDCore.USDStage (source of truth)
    │                                   │ observe (Combine/Observation)
    │                                   ├──▶ ViewportKit: RealityKit scene projection
    │                                   ├──▶ EditorUI: outliner / inspector views
    │                                   └──▶ ValidationKit: live diagnostics
    ▲
EditingKit commands (transform, rename, material edit…)
    — every mutation is a Command: execute()/undo(), applied to the stage,
      stage emits change events, projections update.
```

## Key Protocols (extension points)

```swift
public protocol AssetImporter {           // ConversionKit
    static var supportedExtensions: [String] { get }
    func importAsset(at url: URL, options: ImportOptions) async throws -> USDStage
}

public protocol ConversionStage {         // ConversionKit pipeline step
    var id: String { get }
    func process(_ context: inout ConversionContext) async throws
}

public protocol ValidationRule {          // ValidationKit
    var id: String { get }
    var severity: DiagnosticSeverity { get }
    func evaluate(stage: USDStageProtocol) -> [Diagnostic]
}

public protocol InspectorPanelProvider {  // EditorUI
    func canInspect(_ selection: Selection) -> Bool
    func makePanel(for selection: Selection) -> AnyView
}

public protocol EditCommand {             // EditingKit
    var label: String { get }             // shown in Edit ▸ Undo <label>
    func execute(on stage: USDStageMutable) throws
    func undo(on stage: USDStageMutable) throws
}
```

## Concurrency Model

- Stage mutations serialized on a dedicated `StageActor` (Swift actor). Python GIL interaction is confined to USDBridge's internal executor — one Python interpreter, one dedicated thread, async Swift facade.
- Viewport updates on MainActor; scene rebuilds are diffed (only changed prims re-projected) and debounced at display refresh.
- Conversions and validation run on background task groups; progress reported via `AsyncStream`.

## Error Handling & Logging

- Typed errors per module (`ConversionError`, `BridgeError`, …) with user-facing `recoverySuggestion`.
- Unified `os.Logger` categories per package; log drawer in UI subscribes via OSLogStore.

## Testing Strategy

See `specs/testing.md` — coverage is a CI-enforced per-module gate (100% on all logic modules, high floors + snapshot/golden-image/XCUITest verification on rendering/UI modules, annotated-exclusion discipline). The module boundaries in this document exist partly *for* testability: logic never imports UI or GPU frameworks, so it is 100%-coverable by fast unit tests.

## App Distribution

- Build-from-source is the distribution model: `git clone` → `xcodebuild` (or a `make` wrapper) → app. A build script fetches the Python runtime + usd-core wheel on first build.
- No signing, notarization, sandbox, or App Store constraints — the app can freely spawn processes, load dylibs, and run helper binaries (e.g. FBX2glTF) without entitlement gymnastics.
- Optional convenience: CI publishes unsigned release builds as GitHub Release artifacts (users right-click → Open past Gatekeeper, documented in README).
