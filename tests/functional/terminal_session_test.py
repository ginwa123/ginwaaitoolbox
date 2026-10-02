"""Functional e2e for the right-sidebar terminal HTTP endpoints.

Covers the five REST endpoints backed by the in-memory PTY registry
(src/http_handlers/terminal_*.zig — forkpty, no WebSocket, no
migration, no kabelweb changes):

  * POST   /api/terminal/sessions             {cwd, shell?, cols?, rows?}
    -> 201 { id, pid }
  * POST   /api/terminal/sessions/:id/input   {data}
    -> 200 { ok, bytes } (410 once the shell has exited)
  * GET    /api/terminal/sessions/:id/output?cursor=N
    -> 200 { data, cursor, exited, exit_code }
  * POST   /api/terminal/sessions/:id/resize  {cols, rows}
    -> 200 { ok, cols, rows }
  * DELETE /api/terminal/sessions/:id
    -> 200 { ok } (second delete is 404)

Wire rule: sessions use the harness tempdir as cwd and /bin/sh as the
shell so the test is deterministic on any POSIX host. Output polling
replays the frontend's 300ms poll loop with a hard deadline.
"""

from __future__ import annotations

import time
from typing import Any

import pytest

from harness import FunctionalHarness


# ─── Helpers ───────────────────────────────────────────────────────────────


def _create(
    harness: FunctionalHarness,
    cwd: str | None = None,
    shell: str = "/bin/sh",
    expect: int = 201,
) -> dict[str, Any]:
    body: dict[str, Any] = {"shell": shell}
    if cwd is not None:
        body["cwd"] = str(cwd)
    r = harness.http("POST", "/api/terminal/sessions", json_body=body, expect=expect)
    return r.json()


def _input(
    harness: FunctionalHarness, session_id: str, data: str, expect: int = 200
) -> dict[str, Any]:
    r = harness.http(
        "POST",
        f"/api/terminal/sessions/{session_id}/input",
        json_body={"data": data},
        expect=expect,
    )
    return r.json()


def _output(
    harness: FunctionalHarness, session_id: str, cursor: int = 0, expect: int = 200
) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/terminal/sessions/{session_id}/output?cursor={cursor}",
        expect=expect,
    )
    return r.json()


def _poll_for(
    harness: FunctionalHarness, session_id: str, marker: str, deadline_s: float = 20.0
) -> dict[str, Any]:
    """Poll output until `marker` appears (frontend poll replay)."""
    cursor = 0
    seen = ""
    deadline = time.time() + deadline_s
    last: dict[str, Any] = {}
    while time.time() < deadline:
        last = _output(harness, session_id, cursor)
        chunk = last.get("data", "")
        seen += chunk
        cursor = last.get("cursor", cursor)
        if marker in seen:
            return last
        if last.get("exited") is True:
            break
        time.sleep(0.3)
    raise AssertionError(f"marker {marker!r} never appeared; last={last!r} seen={seen!r}")


def _settle_cursor(
    harness: FunctionalHarness,
    session_id: str,
    quiet_reads: int = 2,
    deadline_s: float = 10.0,
) -> int:
    """Poll forward until the session stops producing output; return the cursor.

    A PTY never really stops: after the marker round-trips, the shell
    redraws its prompt and re-emits the command echo. So a cursor read
    taken the instant the marker shows up can still be behind the
    server's ring buffer, and the NEXT read at that cursor correctly
    returns those not-yet-drained bytes — which looks exactly like a
    replay. Draining until two consecutive reads come back empty is
    what makes "no replay" a statement about the server rather than
    about how fast the test asked.
    """
    cursor = 0
    quiet = 0
    deadline = time.time() + deadline_s
    while time.time() < deadline and quiet < quiet_reads:
        page = _output(harness, session_id, cursor)
        cursor = page.get("cursor", cursor)
        if page.get("data", "") == "":
            quiet += 1
        else:
            quiet = 0
            time.sleep(0.2)
    return cursor


# ─── Test 1: full round-trip ───────────────────────────────────────────────


def test_create_input_output_round_trip(harness: FunctionalHarness) -> None:
    """Create -> echo a marker -> poll until it comes back -> cursor advances."""
    created = _create(harness, cwd=harness.temp_dir)
    session_id = created["id"]
    assert isinstance(session_id, str) and session_id
    assert isinstance(created["pid"], int)

    try:
        marker = "MARKER-9d2c41"
        ack = _input(harness, session_id, f"echo {marker}\n")
        assert ack.get("ok") is True
        assert ack.get("bytes", 0) > 0

        _poll_for(harness, session_id, marker)

        # Let the prompt redraw drain, then hold the cursor fixed: a
        # repeat read at a cursor the server has already served must
        # come back empty. Reading from a cursor taken by a DIFFERENT
        # request (the old `cursor=0` then `fresh["cursor"]` pair) is
        # what raced — see _settle_cursor.
        settled = _settle_cursor(harness, session_id)
        assert settled > 0, "session produced no output at all"
        again = _output(harness, session_id, cursor=settled)
        assert again.get("data", "") == "", (
            f"re-reading from settled cursor {settled} replayed "
            f"{again.get('data', '')!r}"
        )
    finally:
        harness.http("DELETE", f"/api/terminal/sessions/{session_id}", expect=200)


def test_resize_and_delete(harness: FunctionalHarness) -> None:
    """Resize round-trips dims; delete is 200 then 404; output 404s after."""
    created = _create(harness, cwd=harness.temp_dir)
    session_id = created["id"]

    r = harness.http(
        "POST",
        f"/api/terminal/sessions/{session_id}/resize",
        json_body={"cols": 100, "rows": 40},
        expect=200,
    )
    assert r.json().get("cols") == 100
    assert r.json().get("rows") == 40

    # Bad dims are 400, not a resize.
    harness.http(
        "POST",
        f"/api/terminal/sessions/{session_id}/resize",
        json_body={"cols": 1, "rows": 40},
        expect=400,
    )

    gone = harness.http("DELETE", f"/api/terminal/sessions/{session_id}", expect=200)
    assert gone.json().get("ok") is True

    harness.http("DELETE", f"/api/terminal/sessions/{session_id}", expect=404)
    _output(harness, session_id, expect=404)
    _input(harness, session_id, "echo hi\n", expect=404)


def test_create_validation(harness: FunctionalHarness) -> None:
    """Relative cwd is 400; cwd-that-is-a-file is 404; empty cwd falls
    back to the server cwd (201, not 400) so cwd-less chats work."""
    _create(harness, cwd="relative/path", expect=400)
    created = _create(harness, cwd="", expect=201)
    assert created.get("id"), f"expected a session id: {created!r}"
    harness.http("DELETE", f"/api/terminal/sessions/{created['id']}", expect=200)
    _create(harness, cwd="/tmp/nalar-terminal-never-exists-9d2c41", expect=404)

    r = harness.http("POST", "/api/terminal/sessions", expect=400)
    assert "error" in r.json()


def test_unknown_session_is_404(harness: FunctionalHarness) -> None:
    """All per-session endpoints 404 an unknown id (no traversal: the
    id is an opaque registry key, never a path)."""
    _output(harness, "term-does-not-exist", expect=404)
    _input(harness, "term-does-not-exist", "echo hi\n", expect=404)
    harness.http(
        "POST",
        "/api/terminal/sessions/term-does-not-exist/resize",
        json_body={"cols": 80, "rows": 24},
        expect=404,
    )
    harness.http("DELETE", "/api/terminal/sessions/term-does-not-exist", expect=404)


def test_input_after_exit_is_410(harness: FunctionalHarness) -> None:
    """A shell that exits cleanly reports exited + code 0, and further input
    is 410 (not 500).

    Uses the default /bin/sh and asks it to exit rather than spawning
    /bin/true as the "shell". /bin/true is not a shell and the PTY exec of it
    exits 127 on the macOS runners (every _exit(127) path in childMain is a
    chdir/exec failure), so the exit code this test asserts on was never
    produced by /bin/true there. /bin/sh is what every other test in this file
    already spawns successfully on all three platforms, and `exit` gives the
    same deterministic exit-0 the assertion needs.
    """
    created = _create(harness, cwd=harness.temp_dir)
    session_id = created["id"]
    try:
        _input(harness, session_id, "exit\n")
        deadline = time.time() + 15.0
        last: dict[str, Any] = {}
        while time.time() < deadline:
            last = _output(harness, session_id, cursor=last.get("cursor", 0))
            if last.get("exited") is True:
                break
            time.sleep(0.3)
        assert last.get("exited") is True, f"never exited: {last!r}"
        assert last.get("exit_code") == 0, f"expected code 0: {last!r}"

        body = _input(harness, session_id, "echo hi\n", expect=410)
        assert "error" in body
    finally:
        harness.http("DELETE", f"/api/terminal/sessions/{session_id}", expect=200)


def test_two_sessions_are_isolated(harness: FunctionalHarness) -> None:
    """Two sessions on the same server never see each other's bytes:
    a marker sent to A appears only in A's output and vice versa."""
    a = _create(harness, cwd=str(harness.temp_dir))
    b = _create(harness, cwd=str(harness.temp_dir))
    assert a["id"] != b["id"], f"session ids must differ: {a!r} {b!r}"
    try:
        marker_a = "ISOLATION-A-6c1e"
        marker_b = "ISOLATION-B-9f4d"
        _input(harness, a["id"], f"echo {marker_a}\n")
        _input(harness, b["id"], f"echo {marker_b}\n")

        out_a = _poll_for(harness, a["id"], marker_a)
        out_b = _poll_for(harness, b["id"], marker_b)
        assert marker_b not in out_a.get("data", ""), f"A leaked into B: {out_a!r}"
        assert marker_a not in out_b.get("data", ""), f"B leaked into A: {out_b!r}"

        # Full-buffer check: replay from 0 still shows no cross-talk.
        full_a = _output(harness, a["id"], cursor=0)
        full_b = _output(harness, b["id"], cursor=0)
        assert marker_b not in full_a.get("data", "")
        assert marker_a not in full_b.get("data", "")
    finally:
        harness.http("DELETE", f"/api/terminal/sessions/{a['id']}", expect=200)
        harness.http("DELETE", f"/api/terminal/sessions/{b['id']}", expect=200)
