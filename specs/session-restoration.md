# Session Restoration Specification — Restore the Open Document, Its View State, and Undo/Redo Across App Launches

## Scope Statement

This spec covers **cross-launch session restoration**: when the user quits (or the app crashes) with a document open, relaunching offers to bring back the exact working state — the loaded scene, unsaved edits, the full undo/redo history, and the transient view/UI state (selection, gizmo mode, isolation, outliner expansion, panel visibility, camera pose, environment/lighting, playback position).

It is the coordinating layer that ties together primitives that **already exist** in the codebase. It builds nothing at the storage-primitive level that is not already present; it adds the *session envelope*, its persistence, and the app-lifecycle wiring.

### Why this is a gap (review conclusion)

An audit of the codebase (2026-07) found the hard primitives already built, but no layer that coordinates them across launches:

- **Undo/redo already survives via a write-ahead log.** `CommandStack` (EditingKit) journals `JournalRecord`s (`Codable` enum: `.checkpoint`/`.command(label:forward:inverse:)`/`.undo`/`.redo`) through `FileCommandJournal` (JSON-Lines, `fsync` per append). `CommandStack.recover(records:)` + `RecordedCommand` replay that log against the last-saved document to reconstruct the *exact* undo and redo stacks. This is normally the hardest part and it is done.
- **The scene model is `Codable`.** `StageSnapshot` (USDCore) is the document's single source of truth and already serializes.
- **A proven persistence pattern exists.** `CameraBookmarkStore` and `EditorSettings` (EditorUI) each use an `@Observable @MainActor` store over an injectable `UserDefaults`, `Codable` values under stable keys, eager writes, graceful degradation on malformed data, ephemeral suites in tests.

What is missing is purely the coordinator:

- **No `scenePhase` observer and no launch-time restore hook.** `OpenUSDZEditorApp` is a `WindowGroup` (not `DocumentGroup`), so there is no free `NSDocument` autosave/state restoration — it must be hand-rolled.
- **No session descriptor** recording which document was open, its source URL, the associated WAL file, and the transient view/UI state.
- **The WAL is configured per document with no durable, discoverable on-disk home** tying a journal to a document across launches.

### Non-goals

- Multi-window / multi-document restoration. v1 restores the single most-recently-open document only. The data model is nonetheless an *array* of document sessions from day one (length 0 or 1) so multi-window is additive data later, not a schema migration.
- iCloud / cross-device session sync.
- Restoring in-flight long-running operations (conversions, sculpt passes, asset generation). These are re-initiated by the user, not resumed.
- Replacing the eventual `NSDocument` architecture. `UndoManagerBridge` remains the package seam for that; this layer is designed to be retired or absorbed if the app moves to `DocumentGroup`.

## Design decisions (locked)

1. **Restore-but-prompt.** On launch we reconstruct the full document (open source + WAL replay + view state) into a *staged, not-yet-shown* document, then present a lightweight "Restore your previous session?" prompt reporting the unsaved-edit count. Committing shows it; declining deletes the session artifacts and opens clean. Recovery is cheap and reversible, so building before prompting is fine and yields an accurate count.
2. **Single document (v1).** Array-of-one modeling as above.
3. **Application Support files.** Session envelope + relocated WAL live under `~/Library/Application Support/OpenUSDZEditor/Sessions/<sessionID>/`. Security-scoped bookmark data (not raw paths) identifies the source file so it reopens under sandboxing.

## Module: SessionKit (new package)

The session model references types spanning several kits — `StageSnapshot` (USDCore), `EnvironmentSettings` / `ViewportCameraPose` (ViewportKit), `Selection` / gizmo modes / `IsolationState` (EditingKit), and the journal (EditingKit). That crosses too many boundaries to live in any existing leaf module, so it is a dedicated package.

- **Dependencies:** `USDCore`, `ViewportKit`, `EditingKit`. Consumed only by `EditorUI` (wiring) and `App` (lifecycle). Never imports UI (SwiftUI) beyond the `@Observable`/`@MainActor` store; authors no stage itself.
- **Governance (CI-enforced, all in the implementation PR that creates the package):** the `specs/architecture.md §Adding a New Package` checklist applies in full — policy entry in `scripts/dependency-lint.sh`, workspace-layout + dependency-rules update in `architecture.md`, coverage-floor row in `specs/testing.md`, a real test target, inclusion in `scripts/test-all.sh`, and this spec referencing it. This spec PR does **not** create the package or touch the lint script; it only records the contract.

### Types

- **`SessionState`** — versioned `Codable`, `Sendable` value type. Top-level envelope: `schemaVersion: Int` + `documents: [DocumentSession]`.
- **`DocumentSession`** — per open document: `sourceBookmark: Data?` (security-scoped bookmark; nil for a scratch/never-saved scene), `journalRelativePath: String`, `savedRevision: Int`, `sourceFingerprint: SourceFingerprint?` (mtime + size or content hash, for change detection), `embeddedSnapshot: StageSnapshot?` (present only for scratch scenes with no source URL), and `viewState: ViewState`.
- **`ViewState`** — `Codable` sub-struct: selection paths, `gizmoMode`/`gizmoOrientation`/`gizmoPivotMode`, `IsolationState`, outliner `collapsed: Set<PrimPath>`, panel/sheet visibility flags, `EnvironmentSettings`, `ViewportCameraPose`, playback position. Every field degrades to a sensible default when absent.
- **`SessionStore`** — `@Observable @MainActor` coordinator over an injectable `SessionPersistence`. Owns capture (debounced) and restore orchestration.
- **`SessionPersistence`** (protocol) — abstracts *where* the envelope and journals live. Default `FileSessionPersistence` writes to Application Support; tests inject an in-memory/temp backend, mirroring the ephemeral-`UserDefaults` pattern used elsewhere.

## Persistence layout

```
~/Library/Application Support/OpenUSDZEditor/Sessions/
└── <sessionID>/
    ├── session.json      # SessionState envelope (atomic temp-write + rename)
    └── journal.jsonl      # relocated FileCommandJournal WAL (fsync per append)
```

- **Atomic writes** for `session.json` (temp file + rename), exactly as `StageSaver` already does for stage files.
- **Envelope in a file, not UserDefaults**, because it may embed a full `StageSnapshot` and pairs with a growing WAL. (Camera bookmarks / settings stay in UserDefaults — they are tiny prefs, not session data.)
- The WAL keeps its existing `FileCommandJournal` format; only its path becomes session-scoped and discoverable at launch.

## Lifecycle integration

### Capture

- **View-state + embedded snapshot:** debounced writes triggered by the existing `document.revision` / `hasUnsavedChanges` signals — no new change-tracking machinery.
- **Undo/redo:** already eager (the WAL appends per command); no extra capture needed.
- **Durable flush points:** a `scenePhase` observer added to `OpenUSDZEditorApp`, plus `applicationWillTerminate` in `AppDelegate`.

### Restore

Slots into the existing launch `.task` block (which already handles CLI-arg open and the tutorial), and must run *before* an empty document is presented. Flow:

1. Read `SessionState`; if absent/unreadable/newer-schema → open clean (no prompt).
2. For the single `DocumentSession`: resolve the security-scoped bookmark. If the source is missing → offer a soft "couldn't find <file>" notice, not a crash.
3. Open the source via the existing `BridgedStage.open` path to get the baseline snapshot (or use `embeddedSnapshot` for a scratch scene).
4. Compare `sourceFingerprint`; if the file changed on disk since last session, flag it in the prompt (replaying a WAL onto a changed baseline is unsafe).
5. `CommandStack.recover(records:)` to replay the WAL and rebuild undo/redo, then apply `ViewState`, into a staged (hidden) `EditorDocument`.
6. Present the restore prompt with the unsaved-edit count. Commit → show it; decline → delete the session directory and open clean.

## Enterprise-grade concerns

- **Versioning & migration.** `schemaVersion` from day one with a migration switch. Unknown/newer versions degrade to "start fresh," never throw — same philosophy as the existing malformed-data handling.
- **Corruption & partial-write safety.** Atomic envelope writes; a torn WAL tail is treated as recoverable-up-to-last-good-record. A bad session file must never block launch.
- **Security-scoped bookmarks**, not raw paths — required to reopen user files across launches under macOS sandboxing.
- **Change detection.** `sourceFingerprint` guards against replaying edits onto a file that changed underneath us; surfaced in the prompt.
- **Multi-agent / future multi-window.** Session data is keyed per `sessionID`; no single global mutable file that windows would race on. v1 uses one session but the layout already supports many.
- **Determinism.** WAL replay determinism is partly covered by the existing recovery tests; the round-trip invariant below extends that guarantee to the whole envelope.

## Testing

Meets the repo's coverage floor via the injectable `SessionPersistence` (no disk needed for unit tests):

- **Round-trip invariant** (fits `scripts/roundtrip-gate.sh` philosophy): `state → serialize → deserialize → restore → equal state` for `SessionState`/`ViewState`, including empty, scratch-scene (embedded snapshot), and full-view-state cases.
- **Migration:** older `schemaVersion` payloads migrate; newer/unknown degrade to fresh.
- **Corruption:** truncated `session.json`, truncated WAL tail, missing source file, changed-fingerprint — each degrades gracefully and never crashes launch.
- **Recovery composition:** a captured session replays through `CommandStack.recover` to the exact undo/redo depth and stage content (extends existing EditingKit recovery tests).
- **Lifecycle (EditorHarness):** drive the real app — edit, quit, relaunch, assert the prompt appears and commit restores scene + history + view state.

## Phases (acceptance criteria)

1. **SessionKit scaffold** — `SessionState`/`ViewState` models + `SessionPersistence` protocol + governance/spec/lint entries + round-trip tests. No lifecycle yet.
2. **Persistence backend** — `FileSessionPersistence`, atomic writes, versioning/migration, corruption tests.
3. **Single-document lifecycle wiring** — `scenePhase`/launch hooks in App; reuse WAL recovery to restore scene + undo/redo behind the restore prompt.
4. **Full view-state restoration** — selection, gizmo, isolation, outliner expansion, camera, panels, environment, playback.
5. **(Deferred) multi-window / multi-document** + richer "file changed since last session" reconciliation — additive on the array model, no schema break.
