# Diagnostics Logging Specification

`DiagnosticsKit` is the app-wide session logging and crash-breadcrumb system: one log file per app session containing an ordered trail of everything the user (and the agent) did, so a random crash can be tracked down after the fact. It is a pure-Swift, zero-dependency leaf package (like MechanismKit) so every layer — App, EditorUI, CLI, MCP hosts — can adopt it without dependency cycles.

## Record schema

A session log is JSON Lines: one `Breadcrumb` object per line.

| Field | Type | Meaning |
|---|---|---|
| `seq` | UInt64 | Monotonic per session, assigned in `log()` call order — total order even when timestamps collide |
| `timestamp` | ISO 8601 | Wall-clock time |
| `category` | string | Namespaced area — `app.lifecycle`, `edit.command`, `ui.action`, `agent.mcp`, `crash`, … |
| `level` | string | `debug < info < warning < error < fault` |
| `message` | string | Human-readable event |
| `metadata` | {string: string} | Flat structured payload (command label, tool name, error text, …) |

`BreadcrumbCategory` is a raw-string struct, not an enum: **adding a new category is one `static let`** in any module, old readers never fail to decode newer logs, and readers skip undecodable complete lines instead of failing the file.

## File layout

```
Application Support/USDZStudio/Logs/
├── <yyyyMMdd-HHmmss>-<sessionUUID>.log   ← one per app session (SessionLogStore)
└── session.live                          ← crash sentinel (CrashSentinel)
```

The timestamp prefix makes lexicographic order chronological — retention and listings never parse dates.

## Durability policy

Breadcrumbs are diagnostics, not user data, so unlike EditingKit's WAL there is **no fsync per record**. `BreadcrumbLogger` buffers and flushes (one batched write + one fsync via `FileBreadcrumbSink`) when any of:

1. a crumb at or above `.warning` arrives (immediate — trouble usually precedes a crash);
2. the buffer reaches 64 crumbs;
3. the 2-second interval tick;
4. `flush()` / `shutdown()` (the terminate path drains synchronously).

Worst case a hard kill loses ≤2 s of `.debug`/`.info` crumbs. Reads tolerate a torn final line (crash mid-flush), exactly like `FileCommandJournal`. Sink failures are swallowed and the batch dropped: the diagnostics subsystem must never take the app down or grow memory against a failing disk.

## Crash detection

`CrashSentinel` writes `session.live` (sessionID, log file name, start time) on launch and removes it on clean terminate. A sentinel found at launch ⇒ the previous session did not exit cleanly; the new session logs a `crash`-category breadcrumb naming the prior session's log file, whose final crumbs are the trail to the crash. A corrupt sentinel still reports a crash (placeholder identity) — a torn arm write is itself an unclean exit.

**Deliberately no in-process crash handlers** (`signal`, `NSSetUncaughtExceptionHandler`): nothing in a Foundation/JSON stack is async-signal-safe, and a bad handler can corrupt Apple's own crash reports or deadlock. The sentinel answers the same question with zero crash-time code; pair a crashed session's log with the macOS crash report in Console.app for the native stack trace.

## Retention

`enforceRetention` (run at launch): keep at most **20 session logs / 20 MB total**, deleting oldest first; the live session's log is never deleted.

## Integration map

| Site | Category | What is logged |
|---|---|---|
| `App/Sources/DiagnosticsBootstrap.swift` | `app.lifecycle`, `crash` | launch, terminate, scene-phase, prior-session unclean exit |
| `EditorUI.EditorDocument.run/undo/redo` | `edit.command` | every undoable command commit with its label |
| `EditorUI` palette/menu dispatch | `ui.action` | action id + title |
| App MCP activity (`MCPActivityListener`) | `agent.mcp` | agent session/tool start/finish |

Adopting modules receive a `BreadcrumbLogging?` via constructor injection (nil in tests keeps them silent). Console.app mirroring is available via `mirrorToOSLog` (subsystem `com.usdzstudio`). The Help menu's "Reveal Diagnostics Logs" opens the Logs folder in Finder.

## Testing

100% line-coverage floor (`scripts/coverage-gate.sh`). See `specs/testing.md` for the required unit matrix: Codable round-trips, level ordering, sink append/read (torn + undecodable lines), every flush trigger, shutdown semantics, retention by count/bytes with current-file protection, sentinel arm/detect/disarm/corrupt.
