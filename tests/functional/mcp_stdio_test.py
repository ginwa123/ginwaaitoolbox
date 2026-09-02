"""
End-to-end functional test for the MCP stdio transport (plan
2026-08-27-mcp-stdio, Task 5 / PR #365).

This module exercises the full wire path:

  1. **Direct MCP roundtrip** (no nalar involved). Spawn
     `mcp-hello-world` (built by `zig build mcp-hello-world`) via
     `subprocess.Popen`, send it a Content-Length-framed JSON-RPC
     `tools/list` request, parse the response, and assert all 3 tools
     are present. Then send `tools/call print_hello` with a name and
     assert the response contains `"Hello <name>"`.

     This proves the self-test binary + Content-Length framing +
     JSON-RPC dispatch all work end-to-end. It does NOT depend on a
     real LLM.

  2. **nalar accepts stdio mcp_servers config**. Boot nalar with a
     stub LLM profile, PUT a NalarConfig body that includes a
     `mcp_servers` map with one stdio entry (pointing at the
     mcp-hello-world binary), GET the config back, and assert the
     stdio entry round-trips byte-for-byte.

     This proves the backend's `parseMcpServerConfig` accepts the
     stdio shape and the wire round-trips through PUT → on-disk
     JSON → GET. No LLM call is needed because we never send a chat
     message.

  3. **Multi-server**. Add TWO stdio MCP servers with different
     commands + args; assert both round-trip independently through
     the GET path. Proves the registry key-by-name, not by a global
     single-child assumption.

Run:
    pytest tests/functional/mcp_stdio_test.py -v
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from harness import FunctionalHarness, mcp_hello_world_bin


# ─── helpers ──────────────────────────────────────────────────────────────


def _mcp_hello_world_bin() -> Path:
    """Locate the mcp-hello-world wrapper produced by `zig build mcp-hello-world`.

    Delegates to `harness.mcp_hello_world_bin` which raises a skip if
    the binary isn't built; we wrap that as `pytest.skip` for the
    direct-MCP tests so they can be run before the build step.
    """
    try:
        return mcp_hello_world_bin()
    except Exception:
        pytest.skip(
            "mcp-hello-world binary not built; run `zig build mcp-hello-world` first."
        )


def _send_jsonrpc(binary: Path, body: dict, timeout_s: float = 5.0) -> dict:
    """Spawn the binary, send ONE Content-Length-framed JSON-RPC body,
    read ONE response, terminate.

    Returns the parsed JSON-RPC response dict. Raises on timeout /
    parse failure with the captured stderr + partial output.

    Why the trailing `\\n`: the @modelcontextprotocol/sdk writes its
    response asynchronously after parsing the request, and on
    `subprocess.communicate()` Python closes stdin the moment
    `input=` is fully written. The Node child sees stdin EOF,
    dispatches a transport-close handler, and exits BEFORE flushing
    its stdout buffer — so the response never reaches us. Sending one
    extra `\\n` after the body keeps stdin open for an extra
    read-cycle, which gives the SDK time to write the response
    before EOF. (Verified empirically against the smoke.sh path
    which uses a heredoc that adds the trailing `\\n` for the same
    reason.) Without this, the SDK returns nothing — silent failure,
    no error message.
    """
    body_bytes = json.dumps(body, separators=(",", ":")).encode("utf-8")
    # Frame: Content-Length header + LF-LF separator + body + trailing \n.
    # LF separator is what the SDK accepts; CRLF works too but is one
    # extra byte we don't need. separators=(",", ":") keeps the body
    # compact and matches what smoke.sh sends.
    framed = b"Content-Length: " + str(len(body_bytes)).encode("ascii") + b"\n\n" + body_bytes + b"\n"

    try:
        proc = subprocess.Popen(
            [str(binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as e:
        pytest.fail(f"mcp-hello-world binary missing: {binary} ({e})")

    try:
        stdout_b, stderr_b = proc.communicate(input=framed, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        pytest.fail(
            f"mcp-hello-world timed out after {timeout_s}s reading response. "
            f"stderr: {proc.stderr.read().decode('utf-8', errors='replace') if proc.stderr else '<none>'}"
        )

    # The @modelcontextprotocol/sdk v1.x writes NEWLINE-DELIMITED JSON
    # (JSON.stringify(msg) + "\n"), NOT Content-Length framed responses.
    # See src/apps/mcp_hello_world/node_modules/@modelcontextprotocol/sdk/
    # dist/cjs/shared/stdio.js:37 — `serializeMessage` returns
    # `JSON.stringify(message) + '\n'`. Our Zig client
    # (mcp_stdio.zig readFramed) accepts both formats for this reason;
    # the test mirrors that flexibility.
    body_bytes = stdout_b
    if stdout_b.startswith(b"Content-Length:"):
        # Content-Length framed response — strip header.
        sep = stdout_b.find(b"\n\n")
        assert sep > 0, f"no \\n\\n separator in framed response: {stdout_b[:200]!r}"
        body_bytes = stdout_b[sep + 2:]
    try:
        return json.loads(body_bytes.decode("utf-8", errors="replace"))
    except json.JSONDecodeError as e:
        pytest.fail(
            f"failed to parse mcp-hello-world response as JSON: {e}\n"
            f"body: {body_bytes[:300]!r}\n"
            f"stderr: {stderr_b.decode('utf-8', errors='replace')[:200]}"
        )


# ─── Test 1: direct MCP stdio roundtrip ───────────────────────────────────


def test_mcp_hello_world_lists_tools() -> None:
    """mcp-hello-world responds to tools/list with 3 tools."""
    import sys

    if sys.platform == "win32":
        pytest.skip("mcp-hello-world shell wrapper requires POSIX sh")
    binary = _mcp_hello_world_bin()
    resp = _send_jsonrpc(binary, {
        "jsonrpc": "2.0",
        "id": "1",
        "method": "tools/list",
        "params": {},
    })
    assert "result" in resp, f"unexpected response shape: {resp}"
    tools = resp["result"].get("tools", [])
    names = {t["name"] for t in tools}
    assert names == {"print_hello", "print_name", "print_exit"}, (
        f"expected 3 tools, got: {names}"
    )


def test_mcp_hello_world_call_print_hello() -> None:
    """mcp-hello-world tools/call print_hello('MCP') returns 'Hello MCP'."""
    import sys

    if sys.platform == "win32":
        pytest.skip("mcp-hello-world shell wrapper requires POSIX sh")
    binary = _mcp_hello_world_bin()
    resp = _send_jsonrpc(binary, {
        "jsonrpc": "2.0",
        "id": "2",
        "method": "tools/call",
        "params": {
            "name": "print_hello",
            "arguments": {"name": "MCP"},
        },
    })
    assert "result" in resp, f"unexpected response shape: {resp}"
    content = resp["result"].get("content", [])
    assert content, f"empty content: {resp}"
    text = content[0].get("text", "")
    assert text == "Hello MCP", f"unexpected reply text: {text!r}"


def test_mcp_hello_world_call_print_name() -> None:
    """mcp-hello-world tools/call print_name() returns server identity."""
    import sys

    if sys.platform == "win32":
        pytest.skip("mcp-hello-world shell wrapper requires POSIX sh")
    binary = _mcp_hello_world_bin()
    resp = _send_jsonrpc(binary, {
        "jsonrpc": "2.0",
        "id": "3",
        "method": "tools/call",
        "params": {
            "name": "print_name",
            "arguments": {},
        },
    })
    assert "result" in resp, f"unexpected response shape: {resp}"
    text = resp["result"]["content"][0]["text"]
    assert text.startswith("i am "), f"unexpected server identity: {text!r}"
    assert "mcp-hello-world" in text


# ─── Test 2: nalar accepts stdio mcp_servers config ──────────────────────


def test_nalar_config_round_trips_stdio_mcp_servers() -> None:
    """PUT a NalarConfig with stdio mcp_servers → GET preserves the entry.

    This proves the backend's parseMcpServerConfig accepts the stdio
    shape (command + args) AND the wire round-trips through PUT →
    on-disk JSON → GET without losing fields. No LLM call involved —
    the binary boots with a stub profile.
    """
    binary = _mcp_hello_world_bin()
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        # Read whatever config nalar starts with so we can preserve
        # the stub profile + active_profile. PUT replaces the body
        # wholesale, so we must echo the existing top-level fields.
        initial = harness.http("GET", "/api/config/nalar", expect=200).json()

        stdio_entry = {
            "command": str(binary),
            "args": ["--some-flag"],  # the binary ignores these
        }
        put_body = {
            **initial,
            "mcp_servers": {
                "hello": stdio_entry,
            },
        }
        harness.http(
            "PUT", "/api/config/nalar", json_body=put_body, expect=200,
        )

        # GET round-trips.
        got = harness.http("GET", "/api/config/nalar", expect=200).json()
        servers = got.get("mcp_servers") or {}
        assert "hello" in servers, (
            f"stdio MCP server missing from GET response: {list(servers.keys())}"
        )
        hello = servers["hello"]
        assert hello.get("command") == str(binary), (
            f"command mismatch: {hello.get('command')!r}"
        )
        assert hello.get("args") == ["--some-flag"], (
            f"args mismatch: {hello.get('args')!r}"
        )
        # Legacy http entries must NOT have leaked into the stdio entry.
        assert "url" not in hello, (
            f"stdio entry unexpectedly has url field: {hello!r}"
        )
        assert "headers" not in hello
    finally:
        harness.teardown()


def test_nalar_config_round_trips_multiple_stdio_mcp_servers() -> None:
    """Two stdio MCP servers with different commands round-trip independently.

    Proves the mcp_servers map is keyed by name (each entry is its own
    child-spawn config) — not by a global single-child assumption.
    """
    binary = _mcp_hello_world_bin()
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        initial = harness.http("GET", "/api/config/nalar", expect=200).json()
        put_body = {
            **initial,
            "mcp_servers": {
                "alpha": {
                    "command": str(binary),
                    "args": ["--name", "alpha"],
                },
                "beta": {
                    "command": str(binary),
                    "args": ["--name", "beta"],
                    "env": ["FOO=bar"],
                    "cwd": "/tmp",
                },
            },
        }
        harness.http(
            "PUT", "/api/config/nalar", json_body=put_body, expect=200,
        )

        got = harness.http("GET", "/api/config/nalar", expect=200).json()
        servers = got.get("mcp_servers") or {}
        assert "alpha" in servers and "beta" in servers, (
            f"both servers should round-trip: {list(servers.keys())}"
        )
        assert servers["alpha"]["args"] == ["--name", "alpha"]
        assert servers["beta"]["args"] == ["--name", "beta"]
        assert servers["beta"].get("env") == ["FOO=bar"]
        assert servers["beta"].get("cwd") == "/tmp"
    finally:
        harness.teardown()


def test_nalar_config_mixes_http_and_stdio_mcp_servers() -> None:
    """A config with both HTTP and stdio servers round-trips correctly.

    Proves the discriminator (presence of `command` ⇒ stdio,
    presence of `url` ⇒ http) is honored through the wire — neither
    branch collides with the other.
    """
    binary = _mcp_hello_world_bin()
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        initial = harness.http("GET", "/api/config/nalar", expect=200).json()
        put_body = {
            **initial,
            "mcp_servers": {
                "context7": {
                    "url": "https://mcp.context7.com/mcp",
                    "headers": {"X-Token": "secret123"},
                },
                "hello": {
                    "command": str(binary),
                    "args": [],
                },
            },
        }
        harness.http(
            "PUT", "/api/config/nalar", json_body=put_body, expect=200,
        )

        got = harness.http("GET", "/api/config/nalar", expect=200).json()
        servers = got.get("mcp_servers") or {}
        # HTTP entry preserved.
        ctx = servers.get("context7") or {}
        assert ctx.get("url") == "https://mcp.context7.com/mcp"
        assert ctx.get("headers") == {"X-Token": "secret123"}
        assert "command" not in ctx
        # stdio entry preserved.
        hello = servers.get("hello") or {}
        assert hello.get("command") == str(binary)
        assert "url" not in hello
        assert "headers" not in hello
    finally:
        harness.teardown()
