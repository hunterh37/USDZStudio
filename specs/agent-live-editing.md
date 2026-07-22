# Live agent editing in the app viewport

Agent MCP edits (`create_mesh`, `set_transform`, the `sculpt_*` pipeline, …) render **live in the app's 3D viewport**, in the current window, instead of landing in a separate headless process.

## The problem this fixes

`openusdz mcp <file>` (spawned by Claude Code, `.mcp.json`) used to run its **own** `EditSession` on its own file, wholly disconnected from the running editor. The only link was a **one-way activity socket** (NDJSON `session_start`/`tool_*`) — no geometry. So agent edits never reached the viewport; the activity panel updated while the scene stayed empty.

## Design: host the session in the app, relay stdio to it

- **App is the editing authority.** When the editor is running it hosts an `AgentMCPServer` (`MCPActivityListener.bindDocument`) bound to a fresh `EditSession` **seeded from the front `EditorDocument`'s snapshot** — or from an **empty stage when no document is open**, so the host is *always* present. Document-independent methods (`initialize`, `tools/list`) therefore succeed the moment the app is running, and a document-less tool call runs against the scratch stage (its edits mirror nowhere until a document opens, at which point we rebind). `handleRpc` never answers a real request with an empty `line` (which the pump reads as a dropped connection); a missing host yields a JSON-RPC error addressed to the request id. After each request the session's stage is mirrored into the live document via `EditorDocument.applyConsoleEdit(after:label:)` (a `ReplaceStageCommand`), which bumps `revision` → the existing viewport refresh path (`ViewportPane.updateNSView` → `applyScene`/`applyLivePrimPaths`/`applyLiveTransforms`). Agent edits are undoable (`⌘Z`) and the activity panel still works (the hosted server's `MCPEventSink` folds into `MCPActivityModel` via `HostActivitySink`).
- **CLI becomes a pump when the editor is live.** `McpCommand.run` checks for a live endpoint (`RelayPump.liveEndpoint`); if present it runs `RelayPump`: each stdin JSON-RPC line → `rpc_request` frame over the UNIX-domain socket → the app runs it and returns an `rpc_response` frame → written to stdout. When the editor is **not** running, the CLI falls back to today's in-process, file-backed server (unchanged).
- **Concurrency:** the hosted session runs on its own stage (its `CommandStack.onChange` is unset), so `server.handle` executes safely off the main actor; only the mirror (`applyConsoleEdit`) runs on `@MainActor`, where the document is isolated.

## Transport: UNIX-domain socket

The same-machine transport is an **AF_UNIX stream socket**, not loopback TCP.
Loopback TCP (`NWListener(using: .tcp)`) is subject to the macOS Local Network
privacy gate: on recent macOS a fresh app instance intermittently never reached
`.ready`, so no endpoint was ever published and live editing silently broke. A
UNIX socket needs no port and triggers no TCC prompt (so `NSLocalNetworkUsageDescription`
is removed from `App/Info.plist`).

- **Discovery** is unchanged in shape (`…/OpenUSDZEditor/mcp/endpoint.json`) but the
  record now carries `socketPath` (path to `…/mcp/agent.sock`) instead of `port`;
  the `pid`+`token` liveness fields are unchanged.
- **`NWListener`/`NWConnection` don't cleanly support AF_UNIX** on the deployment
  target, so both ends drop to POSIX `socket()/bind()/listen()/accept()` (app,
  `UnixSocketServer`) and `socket()/connect()` (CLI, `UnixSocketClient`) driven by
  `DispatchSource`. Only the transport layer changed — the NDJSON frame contract
  below is identical.
- **Stale sockets:** on bind the app unlinks a leftover `agent.sock` whose owning
  pid (from `endpoint.json`) is dead or is itself, but never one a *different* live
  instance owns (pure decision: `MCPActivityListener.isSocketReclaimable`). On quit it
  removes the endpoint file + socket only if still ours, so a quitting second instance
  can't orphan the first's endpoint.
- **Reclaim, never give up:** if bind fails because a *different live* instance owns the
  socket, the app keeps retrying at a steady cadence (~2 s) for its lifetime rather than
  giving up after a fixed number of tries. When that owner dies (quit **or** crash/kill,
  which skips the on-quit cleanup), the next tick unlinks the dead socket and binds — the
  surviving window takes over serving MCP. Without this, a leftover instance (e.g. a build
  from another window or a `.claude/worktrees/*` checkout) could hold the socket with **no
  document bound**, and the pump would relay `initialize` to it forever and get an empty
  reply → `openusdz: ✘ Failed to connect`.
- **Resilience is preserved:** bounded wait for the endpoint (`awaitEndpoint`),
  per-request reconnect-on-drop with endpoint re-resolution (survives an app
  restart onto a new socket), response timeout, and a spec-shaped JSON-RPC error
  on a lost editor (never a hang).

## Wire protocol (NDJSON, extends the activity socket)

- `rpc_request` `{ v, type, id, line }` — CLI→app, `line` is the raw JSON-RPC request.
- `rpc_response` `{ v, type, id, line }` — app→CLI, `line` is the JSON-RPC response (empty for notifications).
- Legacy activity frames (`session_start`/`tool_started`/`tool_finished`/`session_end`) still decode; in relay mode they're generated in-process by the host instead of sent over the wire.

## Reference panel

An agent reconstructing a model from a reference image can push that image into the editor so the user sees what it is working from. The image shows in a **reference panel above the inspector** (the right column), and is set over the *same* MCP infrastructure as live editing — no new transport.

- **Tools.** `set_reference_image { path, caption? }` and `clear_reference_image` (`Tools+ReferenceImage.swift`, group `.asset`). The image is passed by **absolute path** — the convention the `sculpt_*` tools already use for `referencePath` — so the bytes stay on disk and the app loads them. The tool validates the file exists and stores a `ReferenceImage` (`{path, caption}`) on the `EditSession`, notifying the host via `session.onReferenceImageChange` (a fire-and-forget callback, like `MCPEventSink`; AgentMCP owns no transport). Read back over `usd://reference`.
- **App is live (relay → in-app host).** The callback folds the reference into `ReferenceImageModel` (EditorUI, observed by `ReferenceImagePanel`) on the main actor, and persists the hand-off record. Same seam as the edit mirror in `handleRpc`.
- **App launched by the agent/CLI afterward.** When no editor is running the CLI hosts in-process and persists the reference to a **hand-off file** `…/OpenUSDZEditor/mcp/reference.json` (`ReferenceImage.write`), clearing any stale record at session start. On launch the app reads it (`MCPActivityListener.start` → `ReferenceImage.read`) and seeds the panel, so an image set *before the window existed* still appears. This is the "pass the image in when the app is launched by the agent" path.
- **Boundary.** The reference is **not** USD scene data: it never touches the stage, the `CommandStack`, or undo. `ReferenceImageModel` (EditorUI) carries only plain `path`/`caption` values, since dependency-lint forbids EditorUI from importing AgentMCP; the app (which may import AgentMCP) translates between the two.

## Key files

- `Packages/AgentMCP/.../EditSession.swift` — `init(sharing:stack:…)` (shared-stage seam; also usable for a future zero-copy host).
- `CLI/Sources/RelayPump.swift` — `RelayCodec` (pure frames, unit-tested) + `RelayPump` (IO pump, coverage-disabled). `CLI/Sources/McpCommand.swift` branches to it.
- `CLI/Sources/UnixSocket.swift` — `UnixSocketPath` (pure, unit-tested) + `UnixSocketClient` (AF_UNIX connect/IO, coverage-disabled). Used by both `RelayPump` and `SocketEventSink`.
- `App/Sources/UnixSocketServer.swift` — POSIX AF_UNIX accept loop feeding NDJSON lines to the listener; app target (un-coverage-gated).
- `App/Sources/MCPActivityListener.swift` — `bindDocument`, `handleRpc`, `RpcRequestFrame`/`RpcResponseFrame`, `HostActivitySink`, stale-socket cleanup, `removeEndpointIfOwned`.
- `App/Sources/OpenUSDZEditorApp.swift` — binds the host on launch and on document change; passes `mcp.referenceModel` into the shell.
- `Packages/AgentMCP/.../ReferenceImage.swift` + `Tools+ReferenceImage.swift` — the `{path, caption}` value / hand-off record and the `set_reference_image`/`clear_reference_image` tools; `EditSession.onReferenceImageChange` is the host callback.
- `Packages/EditorUI/.../ReferenceImagePanel.swift` — `ReferenceImageModel` (plain path/caption state), `ReferenceImagePanel`, and `InspectorColumn` (panel above the inspector). Wired in `EditorShellView` via `inspectorColumn`.
- `App/Sources/MCPActivityListener.swift` — `referenceModel`, `applyReference`, `referenceURL`, and the on-launch seed in `start()`.
- Governance: `App` → `AgentMCP` (`scripts/dependency-lint.sh`, `project.yml`, `App/Package.swift`, `specs/architecture.md`). **`EditorUI` still must not import `AgentMCP`.**
- `Packages/RenderKit/.../NativeRenderer.swift` — the concrete `RenderExecuting` backends (`NativeSceneKitRenderer`, `UsdrecordRenderer`, `NativeRendererSelection`, and the pure `RenderStageParse`). Both the CLI (`McpCommand`) and the App (`MCPActivityListener`) inject one via `NativeRendererSelection.make(...)`, so the app-hosted server can satisfy `render_views` and the sculpt review loop without `usdrecord` (#109). Previously the renderer lived in `CLI/` and the app built a Configuration with none, so in-app renders failed.

## Limitations

- The agent session is seeded when the document is bound and is authoritative for its duration; UI edits made *during* an agent session aren't merged back into the agent's stage (rebinding starts fresh). Fine for the agent-driven "watch it build" flow.
- Mirroring uses a whole-forest `ReplaceStageCommand` per request (coarse but correct); a future optimization is the shared-stage host (`EditSession(sharing:)`) once main-actor-safe command execution is wired.

## Verification

- Unit: `SharedSessionTests` (shared-stage init), `RelayCodecTests` (frame encode/decode/drain), `UnixSocketTests` (path-fits + socket/endpoint path derivation), `SocketEventSinkTests` (socket-path endpoint decode). Reference panel: `ReferenceImageToolTests` (set/clear/errors, callback, `usd://reference`, `reference.json` round-trip), `MCPActivityPathsTests` (hand-off path), `ReferenceImageModelTests` (panel state). Gates: `dependency-lint.sh`, `module-governance.sh`, coverage (AgentMCP 100%, CLI ≥95%).
- End-to-end: launch the app (fresh build) with a document open; **reconnect Claude Code's MCP** so it re-spawns the pump CLI; run `create_mesh`/`set_transform`/`remove_prim` and watch the viewport add/clear live; `⌘Z` reverses agent edits.
