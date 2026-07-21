# End-to-End Feature-Flow Testing

This is Test Layer 11 (see `specs/testing.md`). It is the answer to a gap the
other ten layers leave open: unit and property tests prove each module correct
in isolation, the round-trip gate proves the bridge is a fixed point, and the
golden/snapshot/XCUITest layers prove pixels and UI — but nothing asserts that
*composing the major features end to end* produces the right result. A create
command, a material bind, a validate call, and a save each pass their own tests
and still, wired together, can drift. Layer 11 exercises the wiring.

## Seam: the real MCP server, headless

Scenarios drive the product through the same seam an agent (or the live editor)
uses: the `openusdz mcp` JSON-RPC server over stdio, against the real embedded
usd-core bridge. No mocks, no in-process shortcuts — the same tool handlers,
command stack, validation engine, and save path the shipping product runs.

The server is invoked with `--no-relay`. By default `openusdz mcp` relays to a
running editor so an agent edits the document the user has open
(`specs/agent-live-editing.md`); for a test that behaviour is non-determinism —
the gate would assert against whatever a developer happened to have open (and
would be untestable in CI a second way). `--no-relay` forces direct, headless
serving of the fixture under test. The flag lives on the `mcp` subcommand and is
unit-tested in `CLI/Tests/McpCommandTests.swift`.

## Scenarios are data

A scenario is a JSON file under `Tests/E2E/scenarios/`, so a flow is reviewable
in a diff and re-runnable by hand — the same principle as the EditorHarness
`Scenario` format, but at the MCP tool surface rather than the view-model
surface. Shape:

```json
{
  "name": "authoring",
  "open": "../fixtures/cube.usda",
  "strictness": "warn",
  "steps": [
    { "call": "create_mesh", "args": { "name": "Box", "shape": "box" },
      "expect": { "isError": false } },
    { "call": "describe_scene",
      "expect": { "path": ["stats", "meshes"], "equals": 2 } }
  ]
}
```

Each step calls one tool (`call` + `args`) and asserts on its structured result:

- `expect.isError` — the tool call's `isError` flag must match (so both the
  happy path and structured tool-error rejection are assertable).
- `expect.path` + `equals` — dig into `structuredContent` by a key/index path
  and compare for equality.
- `expect.path` + `atLeast` — numeric lower bound at that path.
- `expect.contains` — a substring must appear in the serialized result.

The driver (`scripts/e2e_driver.py`) is a newline-delimited JSON-RPC client: it
spawns the server, sends `initialize`, then one `tools/call` per step, reading
one response line each. It is intentionally small and dependency-free; usd-core
is the only runtime requirement, supplied by the bundled interpreter.

## The gate and its ratchet

`scripts/e2e-gate.sh` runs every scenario and compares its outcome to an
`EXPECTATIONS` table of `<file>|<pass|fail>`. Like `roundtrip-gate.sh`, the gate
is red when reality disagrees with the table **in either direction**: a
declared-pass scenario that fails is a regression; a declared-fail scenario that
starts passing means a known gap closed and the table must be tightened to
`pass`. A flow can neither rot silently nor improve unrecorded. A `fail` row is
only ever for a known, tracked gap and carries a trailing comment with a ROADMAP
reference — never a way to silence a break.

A missing usd-core is a local skip (so the gate never blocks a developer without
the runtime) but a hard failure in CI, where `E2E_REQUIRE_USD=1` is set: green
must mean actually-checked, never "dependency absent."

## Isolation

Each scenario runs against its own throwaway copy of `Tests/E2E`, created per
scenario in a `mktemp` sandbox. A scenario's `save` step writes to its source
stage by design, so without this a save would mutate the committed fixture and
leak into the next scenario. The committed fixtures under `Tests/E2E/fixtures/`
are therefore always pristine, and scenarios are order-independent.

## Adding a scenario (definition of done for a major feature)

A new major feature adds one scenario here as part of its definition of done —
the flow-level equivalent of the per-module coverage floor. Author the smallest
journey that exercises the feature through its tools, assert on the observable
scene/verdict/history via the read tools (`describe_scene`, `query_scene`,
`get_prim`, `list_variants`, `scene_stats`, `validate`, `check_compliance`), add
a fixture under `Tests/E2E/fixtures/` if needed, and add the `pass` row to the
`EXPECTATIONS` table in `scripts/e2e-gate.sh`.
