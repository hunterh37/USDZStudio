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
2. **Single document (v1).** One session directory per document; multi-window is additive later (see Architecture).
3. **Application Support files.** Session envelope + WAL live under `~/Library/Application Support/OpenUSDZEditor/Sessions/<sessionID>/`. A `SourceReference` (bookmark + path) identifies the source file so it reopens across launches; the app is unsandboxed (specs/architecture.md), so a plain bookmark — not a security-scoped one — suffices.

## Architecture: reuse the existing WAL, add the envelope

Implementation revealed that `EditingKit` **already owns** the write-ahead-log half of this feature: `EditingKit.SessionStore` manages a per-document session directory with a `journal.wal` (`FileCommandJournal`, fsync per append) and a `session.live` sentinel, scans for `recoverableSessions()` on relaunch, and turns each leftover WAL into a `RecoveryPlan` (`sourceURL` + the post-checkpoint records). `CommandStack.recovered(...)` replays that plan. Rather than duplicate any of it, this feature *reuses* `EditingKit.SessionStore` for the WAL/recovery/lifecycle and adds only what it lacks: the higher-level **envelope** (which file was open + the transient view state) that lives beside each WAL, and the app wiring.

### SessionKit (new leaf-ish package) — the envelope

- **Dependencies:** `USDCore`, `ViewportKit`, `EditingKit`. Consumed only by `EditorUI`/`App`. Authors no stage; the only concurrency surface is value types + injectable stores.
- **`SessionEnvelope`** — the versioned `Codable` content of `session.json`: `schemaVersion: Int` + `document: DocumentSession`. `isCompatible` gates the discard-on-unknown-version policy (a newer/foreign version is ignored, never throws).
- **`DocumentSession`** — `source: SourceReference?`, `fingerprint: SourceFingerprint?`, `savedRevision: Int`, `embeddedSnapshot: StageSnapshot?` (scratch scenes only), `viewState: ViewState`. `sourceChangedOnDisk()` does the fingerprint check. (No `journalRelativePath` — the WAL is `EditingKit.SessionStore`'s.)
- **`ViewState`** — `Codable` sub-struct: selection paths + primary, `gizmoMode`/`gizmoOrientation`/`gizmoPivotMode` (raw strings, decoupled from the enums), isolate roots, outliner `collapsedPaths`, `panelVisibility`, `CameraState`, `EnvironmentSettings`, playback position. Custom lenient decode: every field defaults when absent, so an older/foreign envelope restores what it can.
- **`CameraState`** — `ViewportCameraPose` as plain `Codable` scalars (the pose wraps a non-`Codable` `SIMD3`), degrading a malformed target to the origin — the same shape `CameraBookmark` uses.
- **`SourceReference`** — bookmark + absolute path with move-resilient resolution (the app is unsandboxed, so a plain bookmark suffices).
- **`SourceFingerprint`** — size + mtime; `matches(fileAt:)` for change detection.
- **`EnvelopeStore`** (protocol) — `write(_:to:)` / `read(from:)` for a session directory. `FileEnvelopeStore` writes `session.json` atomically (temp + replace); `InMemoryEnvelopeStore` backs tests. `read` returns `nil` on absent/corrupt/incompatible — never blocks launch.

### EditingKit additions

- **`CommandStack.checkpointSaved(sourceURL:)`** — on save, flatten the WAL to a fresh checkpoint at the saved file *without* clearing in-session undo history, so recovery replays against the just-saved baseline instead of double-applying pre-save commands. Wired into `EditorDocument.save`.
- **`SessionStore.journal(for:)`** — reopen a recovered plan's WAL so a restored document keeps appending to the same session.
- **`SessionStore.reset()`** — total sweep of every session directory under `root` (active, recoverable, and bare/partial alike); best-effort, never throws, returns the count removed. Backs File ▸ "Reset Session".

### EditorUI — mapping + the session service

- **`EditorDocument`** — journaling initializer (`journal:`), a `restored(baseline:modelURL:journal:records:)` WAL-replay factory with dirty-state reconciliation, and `restoreIsolation`.
- **`SessionMapping`** — `ViewState.capture` / `DocumentSession.capture` and `EditorDocument.applySessionViewState` (selection primary-first, gizmo modes, isolate roots; stale paths + unknown enum values degrade gracefully) + `EditorDocument.restore`.
- **`SessionController`** (`@Observable @MainActor`) — the app-session service composing `EditingKit.SessionStore` + `EnvelopeStore`: `begin(for:)` → `attach` → `capture` → (relaunch) `findRecoverable` → `restore` (adopts the session) → `discard`/`endActive`. It also exposes `reset()` (end the active session + `SessionStore.reset()`) for File ▸ "Reset Session". The scratch-scene baseline is fixed at `attach` time so replay never double-applies.

## Persistence layout

```
~/Library/Application Support/OpenUSDZEditor/Sessions/
└── <sessionID>/
    ├── journal.wal       # EditingKit.SessionStore WAL (fsync per append)
    ├── session.live      # crash sentinel (present ⇒ offer for restore)
    └── session.json      # SessionKit SessionEnvelope (atomic temp-write + replace)
```

Per-`sessionID` directories mean multi-window is additive later (one dir per window), never a schema migration.

## Lifecycle integration (App)

### Capture

- **On open/create/import** (`makeSessionedDocument`): `session.begin(for: url)` starts a fresh WAL session; the document's `CommandStack` is built with its journal (writing the opening checkpoint); `attach` fixes the scratch baseline; `capture` writes the first envelope.
- **Undo/redo:** eager — the WAL appends per command, no extra work.
- **View state:** `capture` on every `scenePhase` transition out of `.active` (background/quit). On a hard kill between transitions the envelope is at worst one background-cycle stale while the WAL (scene + undo/redo) stays current.

### Restore (`offerSessionRestore`, in the launch `.task`, before any document is shown)

1. `session.findRecoverable()` → the newest recoverable session that has a readable envelope; `nil` → clean launch.
2. Only offer when `plan.hasWork` (there were uncommitted edits); a saved-and-quit session is swept silently.
3. Resolve the baseline: reopen `source` via `BridgedStage.open` (bridge), or the `embeddedSnapshot` for a scratch scene. Failure → discard, clean launch.
4. `session.restore(...)` replays the WAL (`CommandStack.recovered`) and applies the view state, building the document up-front (recovery is cheap).
5. Present the restore-or-start-fresh prompt; the message warns when `sourceChangedOnDisk`. Restore → show the rebuilt document; Start Fresh → `discard` + clean launch.

### Reset (File ▸ "Reset Session…", `resetSession`)

A confirmed, destructive command that clears all session-restoration state: `session.reset()` ends the active WAL and sweeps every recoverable leftover so the next launch offers no restore. Any open document stays open and its saved file is untouched; crash-safety is re-armed for it by rebuilding it over a fresh journaled session (undo history resets — the accepted trade-off of an explicit reset). No document open → the sweep alone is the whole effect.

## Enterprise-grade concerns

- **Versioning & migration.** `SessionEnvelope.schemaVersion` from day one; an unrecognized version is discarded (never throws), so a future format can't wedge an older build. Value migrations slot into `FileEnvelopeStore` decode.
- **Corruption & partial-write safety.** Atomic envelope writes; the WAL already tolerates a torn final record (`FileCommandJournal`). A bad envelope or failed rebuild degrades to clean launch, never a crash.
- **No double-apply on save.** `checkpointSaved` rebaselines the WAL at each save; the scratch baseline is frozen at `attach`.
- **Move/rename resilience.** `SourceReference` prefers a bookmark, falls back to the stored path.
- **Change detection.** `SourceFingerprint` (size+mtime) flags a file that changed under a captured session; surfaced in the prompt rather than silently replayed.
- **Multi-agent / future multi-window.** Per-`sessionID` directories; no global mutable file to race on.

## Testing

- **SessionKit (100% floor):** envelope + view-state Codable round-trips, lenient/partial decode, incompatible-version + corrupt + absent envelope reads, `SourceReference` resolution (bookmark / path / fallback / none), `SourceFingerprint` match/mismatch/missing, `DocumentSession.sourceChangedOnDisk`.
- **EditingKit (100% floor):** `checkpointSaved` flattens the log yet keeps undo history (and is a no-op without a journal); `journal(for:)` reopens a plan's WAL.
- **EditorUI:** `ViewState`/`DocumentSession` capture, `applySessionViewState` (primary-first, stale-path/unknown-enum degradation), WAL-replay `restore` (scene + undo + dirty state), and the full `SessionController` lifecycle (begin → capture → relaunch → findRecoverable → restore → discard) against a temp WAL dir + in-memory envelope store.
- **App:** build-only wiring (not coverage-gated by design).

## Phases (status)

1. **SessionKit envelope + models** — ✅ done (`SessionEnvelope`/`DocumentSession`/`ViewState`/`SourceReference`/`SourceFingerprint`/`EnvelopeStore`), 100% coverage.
2. **WAL reuse + save boundary** — ✅ done (reuse `EditingKit.SessionStore`; `checkpointSaved`; `journal(for:)`).
3. **Single-document lifecycle wiring** — ✅ done (`SessionController`; App open/create journaling, scenePhase capture, launch restore prompt; scene + undo/redo restored).
4. **View-state restoration** — ✅ done: document-owned state (selection, gizmo, isolate) via `SessionController.restore`, plus shell-owned state (camera pose, outliner expansion, panel visibility, environment, playback position) captured and reapplied through `EditorShellView` (`captureSession` on scene-phase exit; `applyRestoredViewState` on the restore hand-off). The App threads the restored `ViewState` to the shell and clears it on any normal open so a later document never inherits a stale restore.
5. **(Deferred) multi-window / multi-document** + richer "file changed since last session" reconciliation — additive on the per-session-directory layout, no schema break.
