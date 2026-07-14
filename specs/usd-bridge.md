# USDBridge Specification — Embedding Python + usd-core

## Why this approach

Apple ships no public Swift/C API for authoring USD. Options considered:

1. **Build OpenUSD C++ from source, wrap in C++/Swift interop** — most performant, but a brutal build matrix for contributors and huge binary. Deferred (the module boundary lets us swap in later).
2. **ModelIO only** — read/write support is shallow (no variants, no composition, lossy materials). Insufficient.
3. **Embed CPython + the official `usd-core` PyPI wheel** ✅ — full USD API surface, tiny maintenance burden, and it doubles as the user-facing scripting runtime. Chosen.

## Runtime Layout

```
DicyaninUSDZEditor.app/Contents/Resources/Python/
├── python3.12/            # Python.framework (python.org universal2 build, relocatable)
├── site-packages/
│   └── pxr/ …             # usd-core wheel contents (universal2)
└── stdlib.zip             # zipped stdlib for size
```

- Interpreter embedded **in-process** via `libpython` C API (PythonKit or thin hand-rolled C shim). No subprocesses → works sandboxed, fast round-trips, shared memory for buffers.
- One interpreter, initialized lazily on first stage open, pinned to a dedicated thread (`BridgeExecutor`). All Swift calls hop through an actor onto that thread; GIL never touched from elsewhere.

## Swift Facade

```swift
public final class BridgedStage: USDStageMutable {
    public static func open(url: URL) async throws -> BridgedStage
    public func primTree() async -> Prim                    // snapshot, value type
    public func attribute(_ path: PrimPath, _ name: String) async throws -> AttributeValue
    public func set(_ value: AttributeValue, at: PrimPath, name: String) async throws
    public func definePrim(_ path: PrimPath, type: PrimType) async throws
    public func removePrim(_ path: PrimPath) async throws
    public func save(to url: URL, format: USDFormat, flatten: Bool) async throws
    public var changes: AsyncStream<StageChange> { get }    // fed by Tf.Notice listener
}
```

Design rules:
- **Snapshots out, commands in.** Swift side never holds live Python object references across calls; it receives serialized value-type snapshots (prim trees as flat arrays with parent indices for perf).
- Bulk geometry (points/normals/UVs for the viewport) crosses the boundary as `Data` buffers via Python `memoryview` → zero-copy where possible, one copy worst case.
- `Tf.Notice.ObjectsChanged` registered per stage → forwarded as `StageChange` events (resynced paths) → drives viewport diffing.

## Key usd-core capabilities we lean on

| Feature | API |
|---|---|
| Open/save usdz | `Usd.Stage.Open`, `UsdUtils.CreateNewUsdzPackage` |
| Flatten | `stage.Flatten()` |
| Validation | `usdchecker` module (`UsdUtils.ComplianceChecker`) |
| Diff (tests) | `usddiff` logic via `Sdf` layer comparison |
| Variants | `Usd.VariantSets` |
| Sparse overrides | edit-target on session/root layer |
| Texture packaging | `UsdUtils.ExtractExternalReferences` |

## Viewport Mesh Extraction

RealityKit's own USDZ loader (`Entity(contentsOf:)`) is used for the **fast path** (initial load of an unmodified file — best fidelity for skinned meshes/animations). After edits, changed meshes are re-extracted through the bridge (`UsdGeom.Mesh` points/faceVertexIndices → `MeshDescriptor`). The viewport chooses per-prim between native-loaded entities and bridge-rebuilt ones.

## Failure & Recovery

- Interpreter init failure → app still functions as viewer via RealityKit/ModelIO; editing/conversion features show a "Python runtime unavailable" state with a diagnostics report.
- Python exceptions marshaled to `BridgeError(pythonTraceback:)`, shown in log drawer, never crash the process.
- Watchdog: bridge calls have a configurable timeout; a hung script can be interrupted via `Py_AddPendingCall` → `KeyboardInterrupt`.

## Distribution Note

Since users compile from source, there is no signing/notarization pipeline — the Python.framework and wheel dylibs load without any entitlement or codesigning concerns. This removes the biggest packaging friction of the embedded-interpreter approach entirely.
