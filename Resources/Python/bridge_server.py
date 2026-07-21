#!/usr/bin/env python3
"""Long-lived USD bridge worker.

Where `stage_snapshot.py` is a one-shot (spawn → import pxr → emit → exit),
this stays resident and serves many requests over stdin/stdout, so the
several-hundred-millisecond `import pxr` cost is paid **once per session**
instead of once per file open. It reuses `stage_snapshot.build_snapshot`, so
the emitted JSON is byte-for-byte the same wire format the one-shot produces —
the two can never drift, and `USDBridge.StageSnapshotDecoder` decodes both.

Protocol (framed, so payloads may contain any bytes):

    request   one line of JSON, e.g. {"op": "snapshot", "path": "/x.usdz"}
    response  a header line  "<STATUS> <byte-length>\\n"  then that many bytes
              STATUS is "OK" (payload = JSON snapshot) or "ERR" (payload = utf-8
              error text). A request is answered by exactly one framed response.

Ops: "snapshot" (path → snapshot), "ping" (→ {"ok": true}), "shutdown" (exit).
Reused by USDBridge.PersistentBridgeExecutor.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stage_snapshot import build_snapshot, SnapshotError  # noqa: E402


def _write_frame(status, payload):
    out = sys.stdout.buffer
    out.write(("%s %d\n" % (status, len(payload))).encode("utf-8"))
    out.write(payload)
    out.flush()


def _handle(request):
    """Return (status, payload_bytes) for one decoded request dict."""
    op = request.get("op")
    if op == "ping":
        # Availability means the same thing it does for the one-shot executor:
        # this interpreter can import usd-core.
        try:
            import pxr  # noqa: F401
        except ImportError as exc:
            return "ERR", ("usd-core not importable: %s" % exc).encode("utf-8")
        return "OK", b'{"ok": true}'
    if op == "snapshot":
        try:
            snapshot = build_snapshot(request.get("path", ""))
        except SnapshotError as err:
            return "ERR", err.message.encode("utf-8")
        except Exception as exc:
            # A malformed file makes Usd.Stage.Open *raise* (not return None).
            # The one-shot lets that exit the process; the resident worker must
            # not die on one bad file — report it and stay up for the next open.
            return "ERR", ("could not open stage: %s" % exc).encode("utf-8")
        return "OK", json.dumps(snapshot).encode("utf-8")
    return "ERR", ("unknown op: %r" % op).encode("utf-8")


def main():
    stdin = sys.stdin.buffer
    for line in iter(stdin.readline, b""):
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except Exception as exc:  # malformed request — report, stay alive
            _write_frame("ERR", ("bad request: %s" % exc).encode("utf-8"))
            continue
        if request.get("op") == "shutdown":
            break
        status, payload = _handle(request)
        _write_frame(status, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
