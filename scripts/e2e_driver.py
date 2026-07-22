#!/usr/bin/env python3
"""End-to-end flow driver for OpenUSDZEditor (specs/testing.md §Test Layer 11).

Drives a whole user journey through the *real* product seam — the `openusdz mcp`
JSON-RPC server over stdio, the same transport an agent (or the live editor)
speaks — against the real embedded usd-core bridge. A scenario is authored as
data (JSON), not code, so a flow is reviewable and re-runnable, mirroring the
EditorHarness `Scenario` format but at the MCP tool surface rather than the
view-model surface.

This is a *flow* gate, not a coverage gate: it asserts that composing the major
feature tools end to end produces the right scene, the right verdicts, and the
right undo/redo behaviour — the things per-module line coverage cannot see.

Usage:
    e2e_driver.py --bin PATH_TO_openusdz SCENARIO.json

A scenario:
    {
      "name": "author-cube-material",
      "open": "cube.usda",                # relative to the scenario file's dir
      "strictness": "warn",               # off | warn | strict (optional)
      "steps": [
        { "call": "create_mesh",
          "args": { "name": "Box", "shape": "box" },
          "expect": { "isError": false } },
        { "call": "describe_scene",
          "expect": { "path": ["stats", "meshes"], "equals": 2 } }
      ]
    }

Each step calls one MCP tool and asserts on the structured result:
  expect.isError      — bool; the tool call's isError flag must match.
  expect.path+equals  — dig into structuredContent by key/index path, compare ==.
  expect.path+atLeast — numeric lower bound at that path.
  expect.contains     — substring must appear in the serialized result.

Exit code is 0 iff every step's expectations hold. On failure the offending
step and the actual payload are printed to stderr for a readable CI log.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any


class ScenarioError(Exception):
    """A scenario step failed its expectation (a real, reportable failure)."""


class MCPClient:
    """Newline-delimited JSON-RPC client over a child `openusdz mcp` process."""

    def __init__(self, bin_path: str, stage_path: str, strictness: str) -> None:
        # `--no-relay` forces the server to serve the fixture directly. Without
        # it, the server would attach to whatever document a developer has open
        # in the live editor, making the gate non-deterministic (and useless in
        # CI a second way). We want the file under test, always.
        self._proc = subprocess.Popen(
            [bin_path, "mcp", stage_path, "--no-relay", "--strictness", strictness],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._next_id = 0

    def call_raw(self, method: str, params: dict[str, Any] | None) -> dict[str, Any]:
        self._next_id += 1
        request = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            request["params"] = params
        assert self._proc.stdin and self._proc.stdout
        self._proc.stdin.write(json.dumps(request) + "\n")
        self._proc.stdin.flush()
        line = self._proc.stdout.readline()
        if not line:
            err = self._proc.stderr.read() if self._proc.stderr else ""
            raise ScenarioError(f"server closed the stream during {method}\n{err}")
        return json.loads(line)

    def tool(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        """Call one tool; return its JSON-RPC `result` (content/structuredContent)."""
        response = self.call_raw("tools/call", {"name": name, "arguments": args})
        if "error" in response:
            raise ScenarioError(f"protocol error calling {name}: {response['error']}")
        return response["result"]

    def close(self) -> None:
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
            self._proc.wait(timeout=15)
        except Exception:
            self._proc.kill()


def _dig(payload: Any, path: list[Any]) -> Any:
    """Follow a key/index path into nested dicts/lists; raise if it doesn't exist."""
    node = payload
    for key in path:
        if isinstance(node, list):
            node = node[int(key)]
        elif isinstance(node, dict):
            if key not in node:
                raise ScenarioError(f"path {path!r} missing key {key!r} in {node!r}")
            node = node[key]
        else:
            raise ScenarioError(f"path {path!r} cannot descend into {node!r}")
    return node


def _check(step: dict[str, Any], result: dict[str, Any]) -> None:
    expect = step.get("expect")
    if not expect:
        return
    structured = result.get("structuredContent", {})

    if "isError" in expect:
        actual = bool(result.get("isError", False))
        if actual != bool(expect["isError"]):
            raise ScenarioError(
                f"isError expected {expect['isError']}, got {actual}: {result!r}"
            )

    if "contains" in expect:
        blob = json.dumps(result)
        if expect["contains"] not in blob:
            raise ScenarioError(f"expected substring {expect['contains']!r} not in result")

    if "path" in expect:
        value = _dig(structured, expect["path"])
        if "equals" in expect and value != expect["equals"]:
            raise ScenarioError(
                f"at {expect['path']}: expected {expect['equals']!r}, got {value!r}"
            )
        if "atLeast" in expect and not (value >= expect["atLeast"]):
            raise ScenarioError(
                f"at {expect['path']}: expected >= {expect['atLeast']}, got {value!r}"
            )


def run_scenario(bin_path: str, scenario_path: str) -> None:
    with open(scenario_path) as handle:
        scenario = json.load(handle)

    base = os.path.dirname(os.path.abspath(scenario_path))
    stage = os.path.join(base, scenario["open"])
    if not os.path.isfile(stage):
        raise ScenarioError(f"scenario opens missing stage: {stage}")

    client = MCPClient(bin_path, stage, scenario.get("strictness", "warn"))
    try:
        client.call_raw("initialize", {})
        for index, step in enumerate(scenario["steps"]):
            name = step["call"]
            try:
                result = client.tool(name, step.get("args", {}))
                _check(step, result)
            except ScenarioError as failure:
                raise ScenarioError(
                    f"step {index} ({name}): {failure}"
                ) from None
    finally:
        client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", required=True, help="path to the openusdz binary")
    parser.add_argument("scenario", help="path to a scenario .json")
    args = parser.parse_args()
    try:
        run_scenario(args.bin, args.scenario)
    except ScenarioError as failure:
        print(f"  ✗ {os.path.basename(args.scenario)}: {failure}", file=sys.stderr)
        return 1
    print(f"  ✓ {os.path.basename(args.scenario)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
