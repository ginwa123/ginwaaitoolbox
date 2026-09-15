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

        # A second poll with the fresh cursor returns no replay.
        fresh = _output(harness, session_id, cursor=0)
        assert fresh.get("cursor", 0) > 0
        again = _output(harness, session_id, cursor=fresh["cursor"])
        assert again.get("data", "") == "" or marker not in again.get("data", "")
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
    """Relative/missing cwd is 400; cwd-that-is-a-file is 404."""
    _create(harness, cwd="relative/path", expect=400)
    _create(harness, cwd="", expect=400)
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
    """/bin/true exits immediately: output reports exited + code 0,
    and further input is 410 (not 500)."""
    created = _create(harness, cwd=harness.temp_dir, shell="/bin/true")
    session_id = created["id"]
    try:
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
