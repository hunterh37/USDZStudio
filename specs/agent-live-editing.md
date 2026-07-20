# Live agent editing in the app viewport

Agent MCP edits (`create_mesh`, `set_transform`, the `sculpt_*` pipeline, …) render **live in the app's 3D viewport**, in the current window, instead of landing in a separate headless process.

## The problem this fixes

`openusdz mcp <file>` (spawned by Claude Code, `.mcp.json`) used to run its **own** `EditSession` on its own file, wholly disconnected from the running editor. The only link was a **one-way activity socket** (NDJSON `session_start`/`tool_*`) — no geometry. So agent edits never reached the viewport; the activity panel updated while the scene stayed empty.

## Design: host the session in the app, relay stdio to it

- **App is the editing authority.** When the editor is running it hosts an `AgentMCPServer` (`MCPActivityListener.bindDocument`) bound to a fresh `EditSession` **seeded from the front `EditorDocument`'s snapshot**. After each request the session's stage is mirrored into the live document via `EditorDocument.applyConsoleEdit(after:label:)` (a `ReplaceStageCommand`), which bumps `revision` → the existing viewport refresh path (`ViewportPane.updateNSView` → `applyScene`/`applyLivePrimPaths`/`applyLiveTransforms`). Agent edits are undoable (`⌘Z`) and the activity panel still works (the hosted server's `MCPEventSink` folds into `MCPActivityModel` via `HostActivitySink`).
- **CLI becomes a pump when the editor is live.** `McpCommand.run` checks for a live endpoint (`RelayPump.liveEndpoint`); if present it runs `RelayPump`: each stdin JSON-RPC line → `rpc_request` frame over the localhost socket → the app runs it and returns an `rpc_response` frame → written to stdout. When the editor is **not** running, the CLI falls back to today's in-process, file-backed server (unchanged).
- **Concurrency:** the hosted session runs on its own stage (its `CommandStack.onChange` is unset), so `server.handle` executes safely off the main actor; only the mirror (`applyConsoleEdit`) runs on `@MainActor`, where the document is isolated.

## Wire protocol (NDJSON, extends the activity socket)

- `rpc_request` `{ v, type, id, line }` — CLI→app, `line` is the raw JSON-RPC request.
- `rpc_response` `{ v, type, id, line }` — app→CLI, `line` is the JSON-RPC response (empty for notifications).
- Legacy activity frames (`session_start`/`tool_started`/`tool_finished`/`session_end`) still decode; in relay mode they're generated in-process by the host instead of sent over the wire.

## Key files

- `Packages/AgentMCP/.../EditSession.swift` — `init(sharing:stack:…)` (shared-stage seam; also usable for a future zero-copy host).
- `CLI/Sources/RelayPump.swift` — `RelayCodec` (pure frames, unit-tested) + `RelayPump` (IO pump, coverage-disabled). `CLI/Sources/McpCommand.swift` branches to it.
- `App/Sources/MCPActivityListener.swift` — `bindDocument`, `handleRpc`, `RpcRequestFrame`/`RpcResponseFrame`, `HostActivitySink`.
- `App/Sources/OpenUSDZEditorApp.swift` — binds the host on launch and on document change.
- Governance: `App` → `AgentMCP` (`scripts/dependency-lint.sh`, `project.yml`, `App/Package.swift`, `specs/architecture.md`). **`EditorUI` still must not import `AgentMCP`.**

## Limitations

- The agent session is seeded when the document is bound and is authoritative for its duration; UI edits made *during* an agent session aren't merged back into the agent's stage (rebinding starts fresh). Fine for the agent-driven "watch it build" flow.
- Mirroring uses a whole-forest `ReplaceStageCommand` per request (coarse but correct); a future optimization is the shared-stage host (`EditSession(sharing:)`) once main-actor-safe command execution is wired.

## Verification

- Unit: `SharedSessionTests` (shared-stage init), `RelayCodecTests` (frame encode/decode/drain). Gates: `dependency-lint.sh`, `module-governance.sh`, coverage (AgentMCP 100%, CLI ≥95%).
- End-to-end: launch the app (fresh build) with a document open; **reconnect Claude Code's MCP** so it re-spawns the pump CLI; run `create_mesh`/`set_transform`/`remove_prim` and watch the viewport add/clear live; `⌘Z` reverses agent edits.
