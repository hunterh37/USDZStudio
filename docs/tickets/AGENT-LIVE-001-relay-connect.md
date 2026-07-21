# AGENT-LIVE-001 — `openusdz mcp` reports "Failed to connect" against a live app

**Status:** Fixed (this branch)
**Area:** agent-live editing (`App/Sources/MCPActivityListener.swift`, `specs/agent-live-editing.md`)
**Severity:** High — makes the agent-live feature silently unusable in the common case (app open, second instance present, or no document open).

## Summary

With the editor running, `openusdz mcp <file>` is supposed to relay JSON-RPC over the
UNIX-domain socket to the in-app host so agent edits render live in the open window. In
practice the MCP client (`claude mcp list`) reported `openusdz: ✘ Failed to connect`, and
driving the relay socket directly returned an empty response to `initialize`. The agent
could not operate inside the user's window at all.

Two independent defects combined to produce this, both silent.

## Root cause

### 1. A stale/second instance owns the socket and the survivor never reclaims it

`MCPActivityListener.start()` binds `…/OpenUSDZEditor/mcp/agent.sock` once at launch. If
another **live** instance already owns it (e.g. a leftover debug build from a different
window or a `.claude/worktrees/*` build), the bind loses the race and `restartListener()`
**gave up after 6 tries** (`maxListenerRetries`). From then on that instance never served
MCP, even after the owner died. Meanwhile `endpoint.json` kept pointing at the stale
owner, so the CLI pump faithfully relayed to a zombie **that had no document bound** —
every request came back empty.

Observed in the field: PID 49552 (a build from `.claude/worktrees/feat-stage-diff`, launched
the previous day, no document) owned the socket; the user's real window (PID 80461, this
morning's main build, document open) had backed off and never rebound. Killing 49552 left
a stale socket file that the survivor still did not reclaim.

### 2. A document-less host answers with an empty line, which reads as a dropped connection

Even against the correct instance, `handleRpc` did:

```swift
guard let hostServer, let session = hostSession else {
    send(RpcResponseFrame(id: frame.id, line: ""), on: fd)   // empty line
    return
}
```

`hostServer`/`hostSession` are nil whenever no document is bound, because `bindDocument(nil)`
tore the host down. But `initialize` and `tools/list` need **no** document. The empty `line`
is treated by the pump (`RelayPump.run`) as "no response" (`if !response.isEmpty { print … }`),
so the JSON-RPC handshake never completes and the client reports a bare connection failure
with no diagnostic. Net effect: **app open on an empty window ⇒ agent can never connect**,
which is exactly the "you should have been able to do this inside my single window session"
case.

## Reproduction

1. Launch two editor instances (or leave a stale one from a prior build/worktree running).
2. Open a document in the *second* instance.
3. `claude mcp list` → `openusdz: ✘ Failed to connect`.
4. Probe directly: send an `rpc_request` frame wrapping `initialize` to `agent.sock` →
   reply is `{"type":"rpc_response","line":"","id":1}` (empty `line`).

Also reproduces with a **single** instance when no document is open in the window.

## Fix

`App/Sources/MCPActivityListener.swift`:

- **Always host a session.** `bindDocument` now creates the `AgentMCPServer` even when
  `document == nil`, seeded from an empty `StageSnapshot`, and `handleRpc` calls `ensureHost()`
  first. `initialize`/`tools/list`/tool calls succeed regardless of whether a document is
  open; when one opens we rebind and edits mirror live as before.
- **Never answer with an empty line for a real request.** If a host is somehow still
  unavailable, `handleRpc` returns a proper JSON-RPC error (`jsonrpcError(for:)`) addressed
  to the request id (empty only for notifications, which owe no response) — a correctable
  error instead of a silent hang.
- **Reclaim the socket instead of giving up.** `restartListener()` retries at a steady
  cadence for the app's lifetime (guarded by `wantsListening`/`server == nil`), so when a
  stale owner dies, `cleanupStaleSocket` unlinks its socket and the next tick binds. The
  ownership decision is extracted into the pure `isSocketReclaimable(recordPID:selfPID:isAlive:)`.

## Verification

- `swift build` (App package) — compiles.
- Manual: with a stale instance holding the socket, kill it → the live window rebinds within
  ~2 s and `claude mcp` connects. With a single instance and no document open, `initialize`
  now returns a real handshake and `tools/list` succeeds.

## Follow-ups (not in this change)

- **Ownership hand-off by focus:** whichever window is frontmost with a document could take
  over ownership, so the served instance always matches what the user is looking at. Today
  any always-hosted instance can serve, but the *first* to bind wins.
- **CLI diagnostic:** `openusdz mcp` could log when the relayed `initialize` returns empty
  (pre-fix servers) instead of only surfacing a downstream timeout.
- **Single-instance guard:** consider refusing to launch a second editor instance, or
  namespacing the socket per instance with an explicit "take over" affordance.
