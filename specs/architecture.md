# Architecture Specification

## Goals

Modularity is the product strategy: an open-source contributor should be able to add an importer, an inspector panel, or a validation rule without understanding the whole app. We enforce this with Swift Package Manager module boundaries and one-directional dependencies.

## Workspace Layout

```
USDZStudio/
├── App/                          # Thin app target (SwiftUI lifecycle, DI wiring)
├── Packages/
│   ├── USDCore/                  # Pure Swift USD stage model (no UI, no Python)
│   ├── USDBridge/                # Python/usd-core interop (only module touching Python)
│   ├── MeshKit/                  # Pure Swift half-edge mesh model + topology ops (zero deps)
│   ├── MechanismKit/             # Pure Swift rigid-articulation math: hinge/slider joints, pivot transforms, invariants (zero deps)
│   ├── RigKit/                   # Pure Swift skeletal rig/skinning/motion math: FK, IK/FK solvers, constraints, auto-rig, retargeting, clip blending, motion-quality metric (zero deps)
│   ├── CaptureKit/               # Pure Swift capture-planner: photos→USDZ pre-flight gate, detail→session mapping, staged plan (zero UI/GPU/Python; specs/capture-import.md)
│   ├── ConversionKit/            # Importers, pipeline stages, batch engine
│   ├── ViewportKit/              # RealityKit viewport, camera, gizmos, IBL
│   ├── EditingKit/               # Command layer, undo, stage mutations
│   ├── ValidationKit/            # Rules engine, usdchecker adapter
│   ├── ScriptingKit/             # Python console, script library, CLI core
│   ├── SculptKit/                # Pure staged-sculpt pipeline logic (image→USD spec, passes, gates)
│   ├── SessionKit/               # Cross-launch session envelope + restore (models, persistence, WAL recovery)
│   ├── AgentMCP/                 # MCP server: typed, transactional agent editing API over the kits
│   ├── RenderKit/                # Shared render_views backends (native SceneKit + opt-in usdrecord) for both MCP hosts
│   ├── EditorUI/                 # Panels: outliner, inspector, console, toolbar
│   ├── QuickLookKit/             # Pure render-plan logic for the Finder QuickLook .appex (zero deps)
│   ├── DicyaninDesignSystem/     # Tokens, colors, typography, reusable controls
│   └── DiagnosticsKit/           # Pure Swift per-session breadcrumb logging + crash sentinel (zero deps; specs/diagnostics-logging.md)
├── CLI/                          # openusdz command-line target (links kits, no UI)
├── Resources/Python/             # Bundled Python runtime + usd-core wheel + scripts
├── Tests/                        # Per-package tests + integration corpus tests
└── specs/
```

## Dependency Rules (enforced in CI via a dependency-lint script)

```
App ─▶ EditorUI ─▶ {ViewportKit, EditingKit, ConversionKit, ValidationKit, ScriptingKit} ─▶ USDCore
USDBridge ─▶ USDCore          (bridge implements USDCore protocols)
{EditingKit, ViewportKit, ConversionKit} ─▶ MeshKit   (MeshKit itself imports nothing internal; ConversionKit uses MeshKit.VertexNormals to derive smooth normals for normal-less imports — issue #95)
MechanismKit imports nothing internal (pure leaf, like MeshKit); its consumers ({EditingKit, SculptKit, AgentMCP}) import it for rigid-joint authoring (specs/articulation-mechanisms.md)
DiagnosticsKit imports nothing internal (pure leaf); its consumers ({App, EditorUI}) import it for per-session breadcrumb logging and crash-sentinel detection (specs/diagnostics-logging.md)
RigKit imports nothing internal (pure leaf, like MeshKit/MechanismKit); its consumers ({EditingKit, ViewportKit, AgentMCP}) import it for skeletal rig/skinning/motion authoring (specs/animation-rigging.md)
MechanismKit imports nothing internal (pure leaf); its consumers ({EditingKit, SculptKit, AgentMCP, ViewportKit}) import it for rigid-joint articulation — EditingKit/SculptKit/AgentMCP author joints, ViewportKit reads a joint's axis/pivot/limits for the hinge-axis drag-to-open handle overlay (specs/articulation-mechanisms.md)
CaptureKit ─▶ {USDCore, MeshKit}   (pure capture-planner leaf; consumed by ConversionKit's ObjectCaptureImporter + CLI `capture`; runs no PhotogrammetrySession itself — that is an injected seam in ConversionKit, specs/capture-import.md)
ConversionKit ─▶ CaptureKit         (ObjectCaptureImporter realizes a CapturePlan; the reconstruction session is injected behind PhotogrammetryRunning and coverage-excluded)
SessionKit ─▶ {USDCore, ViewportKit, EditingKit}; consumed by EditorUI/App only — cross-launch session envelope + restore (reuses ViewportKit value types + the EditingKit WAL; authors no stage itself), specs/session-restoration.md
DicyaninDesignSystem ◀─ EditorUI only
QuickLookKit — leaf, zero internal deps (pure render-plan logic; App QuickLook .appex targets consume it)
CLI ─▶ kits (never EditorUI)
SculptKit ─▶ {USDCore, MeshKit}   (pure pipeline logic — spec model, validation, pass state machine; no UI/GPU/Python, authors no stage itself)
EditorUI ─▶ SculptKit             (in-app staged-sculpt runner: applies BuildSteps as live document commands)
EditorUI ─▶ CaptureKit            (capture-import sheet: the detail/profile model + pre-flight gate for photos→USDZ; the reconstruction seam itself comes via ConversionKit, specs/capture-import.md)
App ─▶ AgentMCP                    (composition root hosts the in-app MCP editing session on the open document; specs/agent-live-editing.md. EditorUI still must NOT import AgentMCP)
AgentMCP ─▶ {USDBridge, EditingKit, ValidationKit, ConversionKit, ScriptingKit, MeshKit, SculptKit} ─▶ USDCore   (thin MCP adapter, docs/AGENT_MCP_PLAN.md; never EditorUI)
RenderKit ─▶ {AgentMCP, USDBridge}   (implements AgentMCP.RenderExecuting with a native SceneKit renderer + opt-in usdrecord; consumed by BOTH App and CLI so each hosted MCP server gets a renderer — issue #109)
{App, CLI} ─▶ RenderKit               (composition roots inject the native renderer into their AgentMCPServer.Configuration)
```

The authoritative, machine-checked form of this graph is the policy table in
`scripts/dependency-lint.sh`. The script discovers packages from the
filesystem, so a new package with no policy entry fails CI by construction;
this document and that table must change in the same PR.

- **USDCore never imports Python, RealityKit, or SwiftUI.** It defines `USDStageProtocol`, `Prim`, `Attribute`, `MaterialDescription`, `VariantSet` as value/reference types plus protocols.
- **USDBridge is the only module that links the embedded Python.** It provides the concrete `USDStage` implementation by calling `usd-core`. Swapping it later for a native C++ OpenUSD build changes one module.
- **ViewportKit consumes USDCore models, never USDBridge directly.** RealityKit entities are a derived projection rebuilt from stage-change notifications.
- **MeshKit is pure Swift with zero internal dependencies** (see `specs/mesh-editing.md`): half-edge topology, primitives, and mesh ops. `EditingKit` wraps its ops in undoable commands; `ViewportKit` may consume it for component-overlay rendering. It never imports UI, GPU, or Python frameworks (framework ban enforced by the lint script, same as USDCore).

## Adding a New Package (governance checklist — CI-enforced)

`scripts/module-governance.sh` runs in CI's lint job and fails the build unless
every package under `Packages/` is fully onboarded. To add a package you must,
in the same PR:

1. Add a policy entry to `scripts/dependency-lint.sh` (its allowed internal deps).
2. Add it to the workspace layout and dependency rules in this document.
3. Add a coverage-floor row to `specs/testing.md`.
4. Create its test target with at least one real test.
5. Add it to `scripts/test-all.sh` so the suite runs in CI.
6. Write or extend a spec in `specs/` that references it.

This exists because guardrails that require humans to remember them fail as the
codebase grows — especially with AI agents generating packages quickly.

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
