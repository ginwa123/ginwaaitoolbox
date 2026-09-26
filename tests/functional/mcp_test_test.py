"""
End-to-end functional test for `POST /api/mcp/test` (the "Test" button
on the Add/Edit MCP server modal).

What this exercises:
  1. **stdiosuccess** — fire `tools/list` against the `mcp-hello-world`
     binary (built by `zig build mcp-hello-world`), assert the response
     contains all 3 tools (print_hello, print_name, print_exit).
  2. **stdiobad-command** — fire against a missing command binary,
     assert `{ok: false, ...}` with a "failed to spawn" error.
  3. **http-no-endpoint** — fire against `http://127.0.0.1:1/invalid`
     (connection refused), assert `{ok: false, ...}` with a
     "send failed" error. Doesn't depend on a real HTTP server.
  4. **invalid-transport** — fire with `transport: "weird"`, assert
     `{ok: false, error: "transport must be 'stdio' or 'http'"}`.
  5. **missing-body-field** — stdio with no command, assert
     `{ok: false, error: "command is required for stdio transport"}`.

Why this exists: the "Test" probe was the entire reason the user
filed the kanban task. Before this test, the only coverage was a
config-round-trip test (no actual spawn / tools/list cycle). The
timeout regression for the blocking-bug fix can also surface here —
if the future 10s timeout regresses to no timeout, this test would
hang the suite (caught by pytest's per-test timeout, but the user
would lose time waiting).

Run:
    NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
    pytest tests/functional/mcp_test_test.py -v
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import pytest

from harness import FunctionalHarness, mcp_hello_world_bin


# ─── helpers ──────────────────────────────────────────────────────────────


def _mcp_hello_world_bin() -> Path:
    """Same skip-on-missing helper used by mcp_stdio_test.py."""
    try:
        return mcp_hello_world_bin()
    except Exception:
        pytest.skip(
            "mcp-hello-world binary not built; "
            "run `zig build mcp-hello-world` first."
        )


def _post_test(harness: FunctionalHarness, body: dict, timeout_s: float = 30.0):
    """POST /api/mcp/test and return the parsed JSON. The endpoint
    always returns HTTP 200 (failure surfaces as `ok: false` in the
    body); only an exhausted socket or transport failure raises.
    """
    resp = harness.http(
        "POST", "/api/mcp/test", json_body=body, expect=200, timeout_s=timeout_s,
    )
    result = resp.json()
    if result.get("ok") is False:
        # Surface the actual error for easier debugging when this test fails.
        # The harness captures nalar's stderr to a per-test tmpdir that
        # is wiped on teardown, so the body is the only diagnostic we have.
        print(f"[mcp_test] body: {result}", flush=True)
    return result


# ─── Test 1: stdio success — fires tools/list against mcp-hello-world ──


def test_mcp_test_stdio_success_lists_hello_world_tools() -> None:
    """mcp-hello-world responds to tools/list with 3 tools within
    ~5 seconds. Proves the probe's happy path: spawn child +
    framed send/recv + parse + return tools list.
    """
    if sys.platform == "win32":
        pytest.skip("mcp-hello-world shell wrapper not executable on Windows (requires sh)")
    binary = _mcp_hello_world_bin()
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        start = time.monotonic()
        result = _post_test(harness, {
            "transport": "stdio",
            "command": str(binary),
            "args": [],
        })
        elapsed = time.monotonic() - start
        assert result.get("ok") is True, f"unexpected response: {result}"
        assert result["transport"] == "stdio"
        names = {t["name"] for t in result["tools"]}
        assert names == {"print_hello", "print_name", "print_exit"}, (
            f"expected 3 tools, got: {names}"
        )
        # Whole probe must finish well inside the 10s timeout —
        # 5s is generous for a real node child, no real test wants to
        # wait 10s when the child responds in ~50ms.
        assert elapsed < 10.0, f"probe took {elapsed:.1f}s (>10s timeout!)"
    finally:
        harness.teardown()


# ─── Test 2: stdio bad command — fires tools/list against /no/such/binary


def test_mcp_test_stdio_bad_command_returns_spawn_failure() -> None:
    """A non-existent command binary returns {ok: false, error: ...}
    rather than hanging. Proves the spawn-failed path is reachable
    from the probe.
    """
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        start = time.monotonic()
        result = _post_test(harness, {
            "transport": "stdio",
            "command": "/no/such/binary/should/exist/xyzzy",
            "args": [],
        })
        elapsed = time.monotonic() - start
        assert result.get("ok") is False, f"unexpected response: {result}"
        assert "spawn" in result.get("error", "").lower() or "child" in result.get("error", "").lower(), (
            f"error message should reference spawn/child, got: {result.get('error')!r}"
        )
        assert elapsed < 10.0, f"probe took {elapsed:.1f}s (>10s timeout!)"
    finally:
        harness.teardown()


# ─── Test 3: http unreachable — fires tools/list against a closed port


def test_mcp_test_http_unreachable_returns_send_failure() -> None:
    """An HTTP URL with no server listening returns {ok: false, ...}.
    Probes the HTTP branch of the handler. We use port 1 because the
    kernel will refuse connections — but never use port 8081 which
    the AGENTS.md warns against.
    """
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        start = time.monotonic()
        result = _post_test(harness, {
            "transport": "http",
            "url": "http://127.0.0.1:1/invalid",
        })
        elapsed = time.monotonic() - start
        assert result.get("ok") is False, f"unexpected response: {result}"
        # The error message comes from the libcurl client (e.g.
        # "Connection refused" or "Couldn't connect to server") —
        # we just assert SOMETHING failed fast.
        assert result.get("error"), f"expected non-empty error, got: {result}"
        assert elapsed < 30.0, f"probe took {elapsed:.1f}s (>30s timeout!)"
    finally:
        harness.teardown()


# ─── Test 4: invalid transport discriminator


def test_mcp_test_invalid_transport_returns_clear_error() -> None:
    """transport values other than 'stdio' / 'http' return a readable
    error rather than 500. Guards the catch-block's exhaustive switch.
    """
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        result = _post_test(harness, {
            "transport": "weird-thing",
            "command": "doesn't-matter",
        })
        assert result.get("ok") is False
        assert "transport" in result.get("error", "").lower(), (
            f"error message should reference transport, got: {result.get('error')!r}"
        )
    finally:
        harness.teardown()


def test_mcp_test_missing_command_for_stdio_returns_clear_error() -> None:
    """stdio without `command` returns a clean error rather than 500
    or a spawn attempt with an empty argv (which would be UB)."""
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        result = _post_test(harness, {
            "transport": "stdio",
            "command": "",
        })
        assert result.get("ok") is False
        assert "command" in result.get("error", "").lower()
    finally:
        harness.teardown()


# ─── Regression: spawned MCP children must inherit the parent environment ──
#
# Background (2026-08-31, PR #373): the process-global `StdioRegistry`
# lazily builds its own `std.Io.Threaded` with DEFAULT options. In Zig
# 0.16 the default `InitOptions.environ` is `.empty`, so the `StdioClient`
# spawned via the global registry inherited an EMPTY environment — no
# PATH. A child that resolves its executable by name then fell back to
# libc's hard-coded default path (`/bin:/usr/bin`) and, in CI, could not
# find `node` (actions/setup-node installs it outside that default path),
# surfacing as:
#
#   mcp-hello-world: line 11: exec: node: not found
#
# The fix gives that Threaded the live process environment, but a plain
# "ok:true" assertion can't prove the difference ON A DEV BOX where node
# happens to live on the default fallback path (/usr/bin/node). So this
# test uses a shim command that is reachable ONLY via a non-default PATH
# entry: with the bug the spawned child can't resolve it (empty env →
# default path → not found → SpawnFailed → ok:false); with the fix it
# inherits PATH → resolves → ok:true. It therefore fails closed on any
# future regression that strips the spawned child's environment again.
#

# Minimal in-shell MCP stdio shim (newline-delimited JSON, which
# readFramed auto-detects). Responds to the probe's 3-message handshake
# (initialize → init response, notifications/initialized + tools/list →
# tools response) with one tool ("shim_tool"). Lives at a custom PATH
# entry NOT on the libc default fallback, so it is only resolvable when
# PATH is inherited.
#
# SEQUENCED, not batched (2026-09-04 CI fix): the shim reads ONE request,
# prints the init response, sleeps 0.2s, THEN reads the remaining two
# requests and prints the tools response. The sleep separates the two
# response writes in time so they never coalesce in the kernel pipe
# buffer. Without it the shim printed both responses back-to-back; the
# backend's `readFramed` creates a fresh 4 KiB `Io.Reader` per call
# (stack buffer, discarded on return), so when both lines arrived
# together the first recv buffered + dropped the second line and the
# second recv saw EOF → 20/20 UnexpectedEof, flaky 1-in-3 pass on CI
# and locally. Real MCP servers (Node SDK) never coalesce — they
# process each request on the event loop with a tick between responses
# — so production is unaffected; this is a test-only fidelity fix.
# The 0.2s cost keeps the probe at ~0.2s (well inside the 20s timeout).
SHIM_SERVER = """\
#!/bin/sh
IFS= read -r l1
printf '%s\\n' '{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"shim","version":"1.0"}}}'
sleep 0.2
IFS= read -r l2
IFS= read -r l3
printf '%s\\n' '{"jsonrpc":"2.0","id":"2","result":{"tools":[{"name":"shim_tool","description":"env-inheritance regression guard"}]}}'
"""

SHIM_COMMAND = "mcp-test-env-shim-server"  # unique name, not present in /bin:/usr/bin


def test_mcp_test_stdio_child_inherits_parent_path(tmp_path, monkeypatch) -> None:
    """Children spawned through the global StdioRegistry must inherit the
    parent environment (PATH in particular). The shim command is resolvable
    only via a custom PATH entry outside libc's default fallback, so this
    fails on the empty-env bug and passes once PATH is inherited.
    """
    if sys.platform == "win32":
        pytest.skip("shim server requires /bin/sh, not available on Windows")
    # Place the shim on a PATH entry that is NOT on the glibc default
    # fallback (`/bin:/usr/bin`). Keep the rest of PATH so nalar's own
    # boot (git rev-parse, etc.) still resolves.
    shim_dir = tmp_path / "mcp-shim-bin"
    shim_dir.mkdir()
    shim_file = shim_dir / SHIM_COMMAND
    shim_file.write_text(SHIM_SERVER)
    os.chmod(shim_file, 0o755)

    orig_path = os.environ.get("PATH", "")
    monkeypatch.setenv("PATH", f"{shim_dir}:{orig_path}")

    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        result = _post_test(harness, {
            "transport": "stdio",
            "command": SHIM_COMMAND,  # bare name → PATH resolution by the child
            "args": [],
        }, timeout_s=20.0)
        assert result.get("ok") is True, (
            f"spawned child did not inherit PATH (empty-env regression): {result}"
        )
        assert result["transport"] == "stdio"
        names = {t["name"] for t in result["tools"]}
        assert names == {"shim_tool"}, f"expected shim_tool, got: {names}"
    finally:
        harness.teardown()


# ─── Test 6: TDD example — error response shape ─────────────────────────────
#
# What this exercises:
#   1. Diagnostic info appears in `details` when the probe fails
#      (per-attempt codes + last stderr from the child).
#   2. The cold-start retry path doesn't leak memory (the
#      stdio_children dict in /api/mcp/test doesn't grow unbounded).
#
# Why this test exists:
#   When the SDK crashes during bootstrap on slow CI, the
#   `UnexpectedEof` is the only observable signal from the parent
#   side. We pack the per-attempt outcomes into `details` so the
#   failure mode is visible in the CI log AND the response body —
#   the test asserts both the error shape and that the diagnostic
#   is present, so any future regression that swallows it (e.g. a
#   refactor that drops `out_err_detail`) fails closed here.
def test_mcp_test_stdio_diagnostic_on_child_death() -> None:
    """A child that exits immediately (no MCP protocol) produces a
    diagnostic details string containing the attempt count, per-attempt
    outcome codes, and the child's stderr output.

    We use `false` (always exits 1 with no output) — guaranteed to
    close stdout right after spawn, so the cold-start retry path
    fires deterministically. With 20 attempts × 500ms delay this
    test takes ~12s on the first attempt and ~22s worst case.
    """
    if sys.platform == "win32":
        pytest.skip("false command not available on Windows")
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        start = time.monotonic()
        result = _post_test(harness, {
            "transport": "stdio",
            "command": "false",  # immediate exit; no MCP protocol
            "args": [],
        })
        elapsed = time.monotonic() - start

        assert result.get("ok") is False, f"expected failure, got: {result}"
        # Both the write and the read leg can legitimately lose the race
        # against a child that is already dead: the pipe may be closed
        # before the request goes out (SendFailed) or after it lands but
        # before the reply is read (RecvFailed). mcp_test.zig maps both to
        # a user-facing message, and which one surfaces depends on how far
        # the probe got — so accept either and keep asserting the part
        # that is actually a contract: the failure names the MCP server.
        # Pinning the single recv message here made this test fail ~1 run
        # in 3 on a loaded box (run 2 of 3: 'failed to send request to
        # MCP server' vs the expected 'failed to receive response from
        # MCP server'). The assertions below already accept the same
        # both-paths ambiguity in `details`.
        assert result.get("error") in (
            "failed to receive response from MCP server",
            "failed to send request to MCP server",
        ), f"unexpected error message: {result.get('error')!r}"

        # The DIAGNOSTIC details should now include the per-attempt
        # trace so we can see WHY on CI without ssh'ing in. The format
        # is "<err>|attempts=N/M codes=[<3-char codes>...]|last_stderr=<...>"
        details = result.get("details", "")
        assert "attempts=" in details, (
            f"diagnostic missing attempts count; details={details!r}"
        )
        # The error name should still be there too (back-compat).
        assert "UnexpectedEof" in details or "BrokenPipe" in details or "SendFailed" in details, (
            f"diagnostic missing underlying error name; details={details!r}"
        )
        # The whole probe should finish well within the per-attempt
        # 10s × 20 attempts budget (we give it 30s to be safe).
        assert elapsed < 30.0, f"probe took {elapsed:.1f}s (>30s budget!)"
    finally:
        harness.teardown()


# ─── Test 7: silent child with empty args returns Timeout, not a hang ────────
#
# The user's exact report (2026-09-03): editing an MCP server to have
# EMPTY arguments and clicking Test left the backend blocking forever.
# Empty args means argv=[command] only — for a bare `python` that is
# stdin-script mode: it waits on stdin for EOF (the probe must keep
# stdin open — real MCP servers need it for the session) while writing
# ZERO stdout bytes and staying alive. `readFramed`'s first-byte
# `readSliceShort` blocked forever because the deadline was only polled
# BETWEEN syscalls, never during a zero-byte blocking read.
#
# The fix (`waitReadable` posix.poll guard in mcp_stdio.zig +
# non-blocking `drainStderr` in mcp_test.zig) makes the init recv time
# out after 10s and surfaces `TestError.Timeout`. This test replays the
# exact wire body the modal sends for empty args
# (`argsText "" → []`, command = the python binary) using the test
# runner's own interpreter (guaranteed to exist) and asserts:
#   1. the probe RETURNS (~10s) instead of hanging,
#   2. the error is the Timeout message (not a crash, not a 500 —
#      the endpoint always answers HTTP 200 + {ok:false}),
#   3. a SECOND identical probe also returns (the first failure
#      `markStale`s the hung child; the retry must kill + respawn
#      cleanly instead of wedging the registry).
def test_mcp_test_stdio_empty_args_silent_child_returns_timeout() -> None:
    """Bare interpreter with no args stays silent → {ok:false} Timeout
    within ~10s per probe, backend stays alive across both probes.
    Pre-fix this test never completes (handler thread blocks forever
    on the first-byte read); the harness `timeout_s` turns that hang
    into a failure instead of hanging the suite.
    """
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        body = {
            "transport": "stdio",
            "command": sys.executable,  # bare python, no args
            "args": [],  # modal sends [] for an empty Arguments textarea
        }
        for probe_no in (1, 2):
            start = time.monotonic()
            result = _post_test(harness, body, timeout_s=60.0)
            elapsed = time.monotonic() - start
            assert result.get("ok") is False, (
                f"probe {probe_no}: expected failure, got: {result}"
            )
            assert result.get("error") == "MCP server did not respond within 10 seconds", (
                f"probe {probe_no}: unexpected error message: {result.get('error')!r}"
            )
            assert "RecvTimeout" in result.get("details", ""), (
                f"probe {probe_no}: details should name RecvTimeout; got: {result.get('details')!r}"
            )
            # ~10s deadline + 200ms stderr poll + spawn overhead.
            # 30s bound proves the deadline fired (pre-fix: infinite).
            assert elapsed < 30.0, (
                f"probe {probe_no} took {elapsed:.1f}s (>30s bound — deadline regressed!)"
            )
    finally:
        harness.teardown()


# ─── Test 8: http SSE `event:`-prefixed body parses (context7 shape) ──

# The user's exact report (2026-09-10, screenshot): editing an MCP server
# to `https://mcp.context7.com/mcp` and clicking Test returned
# "Connection failed / failed to parse MCP server response as JSON".
#
# Bisected via curl: context7 answers `200 text/event-stream` with
# `event: message\ndata: {"result":{"tools":[...]}}`. The old
# `parseToolsList` only stripped a leading `data:` prefix, so
# `event:`-prefixed bodies went to the JSON parser verbatim →
# `JsonParseFailed`. The same bisect showed the `_meta` body envelope
# triggers `400 Invalid _meta envelope for protocol revision 2026-07-28`
# while a bare body + `MCP-Protocol-Version`/`Mcp-Method` headers gets
# the lenient 200 — so the probe must send headers but NOT the envelope.
#
# This test replays the exact SSE wire shape against a local stub (no
# external network) and asserts:
#   1. the probe returns {ok:true} with both tools parsed,
#   2. the request carried the spec headers,
#   3. the request body had NO `_meta` envelope.
def test_mcp_test_http_sse_event_prefix_parses_tools() -> None:
    """SSE `event: message` + `data: {...}` body → {ok:true} + tools.
    Pre-fix this returns {ok:false} JsonParseFailed.
    """
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    captured: dict = {}

    TOOLS_JSON = {
        "jsonrpc": "2.0",
        "id": "1",
        "result": {"tools": [
            {"name": "resolve-library-id", "description": "Resolves a lib id"},
            {"name": "query-docs", "description": "Queries docs"},
        ]},
    }
    # Byte-for-byte the context7 shape: event line first, then data.
    SSE_BODY = "event: message\n" + "data: " + json.dumps(TOOLS_JSON) + "\n\n"

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            captured["body"] = self.rfile.read(length).decode("utf-8", "replace")
            captured["protocol_version"] = self.headers.get("MCP-Protocol-Version")
            captured["mcp_method"] = self.headers.get("Mcp-Method")
            raw = SSE_BODY.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        result = _post_test(harness, {
            "transport": "http",
            "url": f"http://127.0.0.1:{port}/mcp",
        })
        assert result.get("ok") is True, f"unexpected response: {result}"
        names = {t["name"] for t in result["tools"]}
        assert names == {"resolve-library-id", "query-docs"}, (
            f"expected 2 SSE tools, got: {names}"
        )
        assert captured.get("protocol_version") == "2025-11-25", (
            f"probe should send MCP-Protocol-Version header, got: {captured!r}"
        )
        assert captured.get("mcp_method") == "tools/list", (
            f"probe should send Mcp-Method header, got: {captured!r}"
        )
        assert "_meta" not in captured.get("body", ""), (
            f"probe body must NOT contain the _meta envelope (400 on 2026-07-28 servers), got: {captured.get('body')!r}"
        )
    finally:
        harness.teardown()
        server.shutdown()
        thread.join(timeout=5.0)
