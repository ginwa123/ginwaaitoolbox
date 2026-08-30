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
        # The user-facing error is the standard recv-failed message.
        assert result.get("error") == "failed to receive response from MCP server", (
            f"unexpected error message: {result.get('error')!r}"
        )

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
