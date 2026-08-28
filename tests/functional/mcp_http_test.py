"""
End-to-end functional test for the MCP Streamable HTTP transport (plan
2026-08-28-mcp-streamable-http, Task 5 / PR #TBD).

This module exercises the full wire path against a live
`mcp-http-hello-world` binary (the test fixture from Task 1):

  1. **Direct MCP roundtrip** (no nalar involved). Spawn
     `mcp-http-hello-world` (built by `zig build mcp-http-hello-world`)
     via `subprocess.Popen` on a free port, wait for the "listening on"
     stderr line, POST a `tools/list` request to `/mcp` with the
     spec-mandated `MCP-Protocol-Version: 2025-11-25` header, parse the
     SSE response, and assert all 3 tools are present. Then POST
     `tools/call` for `print_hello` with `name=world` and assert the
     response text is `"Hello world"`.

     This proves the self-test binary + Streamable HTTP wire + JSON-RPC
     dispatch all work end-to-end. It does NOT depend on nalar's HTTP
     client (which lands in Tasks 2-4 of the plan).

  2. **(Future) nalar accepts http mcp_servers config** — added when
     Tasks 2-4 land. Boot nalar with a stub LLM profile, PUT a
     NalarConfig body that includes `mcp_servers.http_test = { url }`,
     GET the config back, and assert the url round-trips.

  3. **(Future) Multi-server** — added when Tasks 2-4 land. Two HTTP
     servers with different commands, both round-trip independently.

Run:
    NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \\
      python3 -m pytest tests/functional/mcp_http_test.py -v
"""

from __future__ import annotations

import json
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness, mcp_http_hello_world_bin


# ─── helpers ──────────────────────────────────────────────────────────────


def _find_free_port() -> int:
    """Bind to port 0 on 127.0.0.1, read the assigned port, release the
    socket. Same pattern as the Zig test's getFreePort helper."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _spawn_mcp_http_hello_world(port: int, timeout_s: float = 5.0) -> subprocess.Popen[bytes]:
    """Spawn the mcp-http-hello-world binary on `port` and wait for
    the "listening on" stderr line. Returns the Popen handle; caller
    is responsible for terminate()+wait() on teardown.

    Raises RuntimeError on timeout or spawn failure.
    """
    binary = mcp_http_hello_world_bin()  # raises pytest.skip if not built
    proc = subprocess.Popen(
        [str(binary), str(port)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + timeout_s
    # Read stderr line-by-line until we see "listening on" OR the
    # process exits. Use a short poll interval to avoid blocking on
    # readline() if the process never writes.
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            # Process exited before printing "listening on" — gather
            # the stderr we DID get and surface it.
            try:
                _, stderr = proc.communicate(timeout=1.0)
            except subprocess.TimeoutExpired:
                stderr = b""
            raise RuntimeError(
                f"mcp-http-hello-world exited rc={proc.returncode} before "
                f"listening on port {port}\nstderr:\n"
                + stderr.decode("utf-8", errors="replace")
            )
        # Non-blocking read: check if a line is available. We use a
        # short sleep + .readline() with a 100ms timeout via the
        # underlying file object's setblocking? No, simpler: just
        # sleep 50ms in a tight loop. The binary prints "listening on"
        # ~10ms after start, so this converges fast.
        time.sleep(0.05)
        # Poll the stderr buffer without blocking. We can't easily
        # do a non-blocking read on Popen.stderr (it's a Python file
        # object), so instead we set a tiny read timeout via select().
        # Simpler: use os.read on the underlying FD.
        import os
        import select
        if proc.stderr is None:
            continue
        fd = proc.stderr.fileno()
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        chunk = os.read(fd, 4096)
        if not chunk:
            continue
        text = chunk.decode("utf-8", errors="replace")
        if "listening on" in text:
            return proc
    proc.kill()
    proc.wait(timeout=2.0)
    raise RuntimeError(
        f"mcp-http-hello-world did not print 'listening on' within {timeout_s}s"
    )


def _parse_sse_response(body: str) -> dict[str, Any]:
    """Parse an SSE response body, return the LAST event's data field as
    a parsed JSON object. Mirrors the JS test helper in
    src/apps/mcp_http_hello_world/server.test.ts — same algorithm,
    same edge cases (comments, multi-data lines, etc)."""
    events = [e for e in body.split("\n\n") if e.strip()]
    last_data: str | None = None
    for raw_event in events:
        data_lines: list[str] = []
        for line in raw_event.split("\n"):
            if line.startswith(":"):
                continue  # SSE comment, ignore
            if line.startswith("data:"):
                value = line[len("data:"):]
                if value.startswith(" "):
                    value = value[1:]
                data_lines.append(value)
        if data_lines:
            last_data = "\n".join(data_lines)
    if last_data is None:
        raise AssertionError(
            f"SSE stream with no data: events\nbody:\n{body[:500]}"
        )
    return json.loads(last_data)


def _post_jsonrpc(base_url: str, body: dict[str, Any], timeout_s: float = 5.0) -> dict[str, Any]:
    """POST a JSON-RPC body to /mcp and return the parsed JSON response.

    The server may respond with `application/json` (single JSON object)
    or `text/event-stream` (SSE stream — last event's data: field is
    the final response). We dispatch on Content-Type and return the
    parsed JSON-RPC response in both cases.

    The MCP-Protocol-Version header is required by the spec (and
    enforced by the SDK with 400 Bad Request if missing). We send
    2025-11-25 (the latest revision @modelcontextprotocol/sdk v1.30.0
    implements).
    """
    import urllib.request

    payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/mcp",
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-11-25",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        content_type = resp.headers.get("Content-Type", "")
        text = resp.read().decode("utf-8")
    if content_type.startswith("application/json"):
        return json.loads(text)
    if content_type.startswith("text/event-stream"):
        return _parse_sse_response(text)
    raise AssertionError(
        f"unexpected content-type: {content_type}\nbody: {text[:500]}"
    )


# ─── tests ───────────────────────────────────────────────────────────────


def test_http_mcp_direct_roundtrip_no_nalar() -> None:
    """Direct MCP wire roundtrip — no nalar involved. Spawn the
    mcp-http-hello-world binary, POST a tools/list + a tools/call,
    assert the responses match what the SDK server would return.

    This is the test fixture's wire contract smoke test. The same
    algorithm runs in the Zig vitest test
    (src/apps/mcp_http_hello_world/server.test.ts); this Python
    version exercises the BUILT binary as installed by
    `zig build mcp-http-hello-world` at zig-out/bin/.
    """
    port = _find_free_port()
    proc = _spawn_mcp_http_hello_world(port)
    try:
        base_url = f"http://127.0.0.1:{port}"
        # 1. tools/list — assert all 3 tools advertised.
        list_resp = _post_jsonrpc(base_url, {
            "jsonrpc": "2.0",
            "id": "1",
            "method": "tools/list",
            "params": {},
        })
        assert list_resp["jsonrpc"] == "2.0"
        assert list_resp["id"] == "1"
        tool_names = sorted(
            t["name"] for t in list_resp["result"]["tools"]
        )
        assert tool_names == ["print_exit", "print_hello", "print_name"]

        # 2. tools/call print_hello with name="world" — assert "Hello world".
        hello_resp = _post_jsonrpc(base_url, {
            "jsonrpc": "2.0",
            "id": "2",
            "method": "tools/call",
            "params": {"name": "print_hello", "arguments": {"name": "world"}},
        })
        assert hello_resp["id"] == "2"
        hello_text = hello_resp["result"]["content"][0]["text"]
        assert hello_text == "Hello world"

        # 3. tools/call print_name — assert server identity.
        name_resp = _post_jsonrpc(base_url, {
            "jsonrpc": "2.0",
            "id": "3",
            "method": "tools/call",
            "params": {"name": "print_name", "arguments": {}},
        })
        assert name_resp["id"] == "3"
        name_text = name_resp["result"]["content"][0]["text"]
        assert name_text == "i am mcp-http-hello-world v0.0.1"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2.0)


def test_http_mcp_missing_protocol_version_is_lenient() -> None:
    """Spec (revision 2025-11-25) says: 'A server that supports
    clients implementing protocol versions earlier than 2025-06-18
    (which did not define the MCP-Protocol-Version header) MAY treat
    a request that omits the header as protocol version 2025-03-26.'

    The @modelcontextprotocol/sdk v1.30.0 implements the lenient
    path: requests without MCP-Protocol-Version succeed (it treats
    them as 2025-03-26). We document this here so future nalar
    client code knows the wire behavior.

    IMPORTANT for our nalar HTTP client: while the server is LENIENT,
    we should still ALWAYS send the header (it's spec-required for
    protocol versions >= 2025-06-18). Sending the header is the
    correct client behavior; not sending it is a legacy fallback
    that may go away in a future spec revision.
    """
    import urllib.request

    port = _find_free_port()
    proc = _spawn_mcp_http_hello_world(port)
    try:
        base_url = f"http://127.0.0.1:{port}"
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": "1",
            "method": "tools/list",
            "params": {},
        }).encode("utf-8")
        # Note: NO MCP-Protocol-Version header.
        req = urllib.request.Request(
            f"{base_url}/mcp",
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
        )
        # Server treats missing header as 2025-03-26 → request
        # SUCCEEDS (200 OK), same as a spec-compliant request.
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            assert resp.status == 200
            body = resp.read().decode("utf-8")
        # Parse the response (JSON or SSE).
        if "event:" in body:
            parsed = _parse_sse_response(body)
        else:
            parsed = json.loads(body)
        assert parsed["jsonrpc"] == "2.0"
        assert parsed["id"] == "1"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2.0)


def test_http_mcp_unsupported_protocol_version_returns_400() -> None:
    """Targeting a protocol revision the server doesn't support must
    return 400 with an UnsupportedProtocolVersion error. We send
    "1999-01-01" (a deliberately bogus version) and expect 400.
    """
    import urllib.request
    import urllib.error

    port = _find_free_port()
    proc = _spawn_mcp_http_hello_world(port)
    try:
        base_url = f"http://127.0.0.1:{port}"
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": "1",
            "method": "tools/list",
            "params": {},
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{base_url}/mcp",
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Protocol-Version": "1999-01-01",  # bogus
            },
        )
        with pytest.raises(urllib.error.HTTPError) as excinfo:
            urllib.request.urlopen(req, timeout=5.0)
        assert excinfo.value.code == 400
        body = excinfo.value.read().decode("utf-8")
        err = json.loads(body)
        assert err.get("jsonrpc") == "2.0"
        assert "error" in err
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2.0)
