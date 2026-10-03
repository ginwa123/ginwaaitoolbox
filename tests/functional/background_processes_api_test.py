"""Functional e2e for session background-process HTTP endpoints.

Covers the two read-only endpoints added for the frontend pill/dialog
(no new SSE event, no migration, no watcher/cron change):

  * GET /api/llm/session/:session_id/background_processes
    -> 200 { processes: [{ pid, command, log_path, started_at,
                           status, running }], count }
  * GET /api/llm/session/:session_id/background_processes/:pid/log
    [?max_bytes=N]
    -> 200 { pid, log_path, total_bytes, truncated, content }
    (content is the TAIL — the last max_bytes of the file).

Setup pattern (replay-frontend-wire-payload rule): sessions are created
via PUT /api/llm/session/:id {"name": ...} (session_update.zig
auto-creates via ensureSessionExists — same helper as
background_command_completion_test.py::_create_session, no LLM profile
needed). Bg rows are inserted via direct sqlite3 into the isolated
HOME's agent.db (Path(harness.temp_dir)/.config/nalar/agent.db — WAL
mode makes the concurrent open safe). The dead PID (999999999) can
never be alive: it exceeds Linux's max PID so kill(pid, 0) returns
ESRCH -> running == false. The live PID is the harness's own
os.getpid() -> running == true.

Endpoints are synchronous — no polling needed.
"""

from __future__ import annotations

import os
import sqlite3
import time
from pathlib import Path
from typing import Any

from harness import FunctionalHarness

# A PID that can never be alive on Linux (max pid is 4194304 by
# default; kill(999999999, 0) -> ESRCH). Fits in i32/u32 so both the
# cron's parseInt(i32) and the endpoint's parseInt(u32) accept the row.
DEAD_PID = 999999999
DEAD_PID_2 = 999999998


# ─── Helpers ───────────────────────────────────────────────────────────────


def _db_path(harness: FunctionalHarness) -> Path:
    """Agent DB inside the isolated tmpdir HOME (Linux layout)."""
    return Path(harness.temp_dir) / ".config" / "nalar" / "agent.db"


def _create_session(harness: FunctionalHarness, session_id: str) -> dict[str, Any]:
    """PUT auto-creates the sessions row (ensureSessionExists); no LLM needed."""
    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": f"bg-api-{session_id}"},
        expect=200,
    )
    return r.json()


def _insert_bg_row(
    harness: FunctionalHarness,
    session_id: str,
    pid: int,
    command: str,
    log_path: str,
    status: str = "running",
) -> None:
    """Insert a session_background_process row while the binary runs.

    Short-lived connection + commit + close (WAL-safe; same precedent
    as background_command_completion_test.py). Schema mirrors migration
    014: (session_id, pid, command, log_path, started_at, status) with
    composite PK (session_id, pid).
    """
    conn = sqlite3.connect(f"file:{_db_path(harness)}?mode=rw", uri=True)
    try:
        conn.execute(
            "INSERT INTO session_background_process"
            " (session_id, pid, command, log_path, started_at, status)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (session_id, pid, command, log_path, int(time.time()), status),
        )
        conn.commit()
    finally:
        conn.close()


def _get_list(harness: FunctionalHarness, session_id: str) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/background_processes",
        expect=200,
    )
    return r.json()


def _get_log(
    harness: FunctionalHarness,
    session_id: str,
    pid: int,
    max_bytes: int | None = None,
    expect: int = 200,
) -> dict[str, Any]:
    path = f"/api/llm/session/{session_id}/background_processes/{pid}/log"
    if max_bytes is not None:
        path += f"?max_bytes={max_bytes}"
    r = harness.http("GET", path, expect=expect)
    return r.json()


# ─── Test 1: empty session -> 200 { processes: [], count: 0 } ───────────────


def test_list_empty_for_fresh_session(harness: FunctionalHarness) -> None:
    """A session with no bg rows returns an empty list (200, not 404)."""
    session_id = "sess_bg_api_empty_001"
    _create_session(harness, session_id)

    body = _get_list(harness, session_id)
    assert body.get("processes") == [], f"expected [], got {body.get('processes')!r}"
    assert body.get("count") == 0, f"expected count=0, got {body.get('count')!r}"


# ─── Test 2: list shape + live running flags ────────────────────────────────


def test_list_shape_and_running_flags(harness: FunctionalHarness) -> None:
    """Seeded rows come back with the exact wire shape; `running` is
    computed live (dead PID -> false, own PID -> true) regardless of
    the status column."""
    session_id = "sess_bg_api_list_001"
    _create_session(harness, session_id)

    live_pid = os.getpid()
    live_log = str(Path(harness.temp_dir) / "bg-api-live.log")
    Path(live_log).write_text("live output\n", encoding="utf-8")
    dead_log = str(Path(harness.temp_dir) / "bg-api-dead.log")
    Path(dead_log).write_text("dead output\n", encoding="utf-8")

    # Dead row keeps status='running' (stale-column case); live row
    # keeps status='completed' (inverse stale case) — the endpoint
    # must report OS truth either way.
    _insert_bg_row(harness, session_id, DEAD_PID, "sleep 10", dead_log, status="running")
    _insert_bg_row(harness, session_id, live_pid, "pytest-probe", live_log, status="completed")

    body = _get_list(harness, session_id)
    assert body.get("count") == 2, f"expected count=2, got {body!r}"
    procs = {p["pid"]: p for p in body.get("processes", [])}
    assert set(procs) == {DEAD_PID, live_pid}, f"pid keys mismatch: {sorted(procs)!r}"

    for p in procs.values():
        for key in ("pid", "command", "log_path", "started_at", "status", "running"):
            assert key in p, f"process entry missing {key!r}: {p!r}"
        assert isinstance(p["pid"], int), f"pid must be a number: {p!r}"
        assert isinstance(p["started_at"], int), f"started_at must be a number: {p!r}"
        assert isinstance(p["running"], bool), f"running must be a bool: {p!r}"

    assert procs[DEAD_PID]["command"] == "sleep 10"
    assert procs[DEAD_PID]["log_path"] == dead_log
    assert procs[DEAD_PID]["running"] is False
    assert procs[live_pid]["command"] == "pytest-probe"
    assert procs[live_pid]["running"] is True
    # Status column is echoed verbatim (not overwritten by live-ness).
    assert procs[live_pid]["status"] == "completed"


def test_list_scoped_to_session(harness: FunctionalHarness) -> None:
    """Rows for another session never leak into this session's list."""
    session_a = "sess_bg_api_scope_a_001"
    session_b = "sess_bg_api_scope_b_001"
    _create_session(harness, session_a)
    _create_session(harness, session_b)

    _insert_bg_row(harness, session_a, DEAD_PID, "cmd-a", "/tmp/bg-scope-a.log")
    _insert_bg_row(harness, session_b, DEAD_PID_2, "cmd-b", "/tmp/bg-scope-b.log")

    body = _get_list(harness, session_a)
    assert body.get("count") == 1, f"expected count=1, got {body!r}"
    assert body["processes"][0]["command"] == "cmd-a"


# ─── Test 3: log tail ───────────────────────────────────────────────────────


def test_log_full_content_under_cap(harness: FunctionalHarness) -> None:
    """A small log returns its full content with truncated=false."""
    session_id = "sess_bg_api_log_full_001"
    _create_session(harness, session_id)

    content = "line one\nline two\ntail-marker-3e8f1a\n"
    log_path = str(Path(harness.temp_dir) / "bg-api-full.log")
    # BINARY, not `write_text`. Text mode translates "\n" to "\r\n" on
    # Windows, so the file on disk held 40 bytes while this test asserted
    # `len(content.encode())` == 37 — and the server, which correctly
    # reported the real size and the real bytes it found, failed:
    #
    #   total_bytes mismatch: {... 'total_bytes': 40, 'truncated': False,
    #   'content': 'line one\r\nline two\r\ntail-marker-3e8f1a\r\n'}
    #   assert 40 == 37
    #
    # Nothing is wrong with the product here: it reported exactly what was in
    # the file. The test just meant to put 37 specific bytes on disk and got
    # 40, because it used a text-mode write for a byte-count assertion.
    # Writing bytes makes the fixture platform-independent and states the
    # intent outright — this log contains these exact bytes.
    #
    # `test_log_tail_when_over_cap` needs no equivalent change: its payload
    # has no newline, so text mode writes it byte for byte.
    Path(log_path).write_bytes(content.encode("utf-8"))
    _insert_bg_row(harness, session_id, DEAD_PID, "sleep 10", log_path)

    body = _get_log(harness, session_id, DEAD_PID)
    assert body.get("pid") == DEAD_PID, f"pid mismatch: {body!r}"
    assert body.get("log_path") == log_path, f"log_path mismatch: {body!r}"
    assert body.get("total_bytes") == len(content.encode()), f"total_bytes mismatch: {body!r}"
    assert body.get("truncated") is False, f"expected truncated=false: {body!r}"
    assert body.get("content") == content, f"content mismatch: {body.get('content')!r}"


def test_log_tail_when_over_cap(harness: FunctionalHarness) -> None:
    """A log bigger than max_bytes returns the LAST max_bytes bytes
    with truncated=true and the full size in total_bytes."""
    session_id = "sess_bg_api_log_tail_001"
    _create_session(harness, session_id)

    head_marker = "HEAD-marker-aaaa"
    tail_marker = "TAIL-marker-zzzz"
    payload = head_marker + ("A" * 500) + tail_marker
    log_path = str(Path(harness.temp_dir) / "bg-api-tail.log")
    Path(log_path).write_text(payload, encoding="utf-8")
    _insert_bg_row(harness, session_id, DEAD_PID, "make", log_path)

    body = _get_log(harness, session_id, DEAD_PID, max_bytes=100)
    assert body.get("total_bytes") == len(payload.encode()), f"total_bytes mismatch: {body!r}"
    assert body.get("truncated") is True, f"expected truncated=true: {body!r}"
    content = body.get("content", "")
    assert len(content.encode()) == 100, f"expected 100 tail bytes, got {len(content.encode())}: {content!r}"
    assert content.endswith(tail_marker), f"tail must end with marker: {content!r}"
    assert head_marker not in content, f"head must be cut off: {content!r}"


def test_log_missing_file_returns_not_found_marker(harness: FunctionalHarness) -> None:
    """A row whose log file is gone returns 200 with the
    "(log file not found)" marker and total_bytes 0 (queue-marker
    convention — not a 404)."""
    session_id = "sess_bg_api_log_missing_001"
    _create_session(harness, session_id)

    _insert_bg_row(
        harness, session_id, DEAD_PID, "sleep 5", "/tmp/nalar-bg-api-never-exists-4244.log"
    )

    body = _get_log(harness, session_id, DEAD_PID)
    assert body.get("total_bytes") == 0, f"expected total_bytes=0: {body!r}"
    assert body.get("truncated") is False, f"expected truncated=false: {body!r}"
    assert body.get("content") == "(log file not found)", f"marker mismatch: {body!r}"


def test_log_unknown_pid_returns_404(harness: FunctionalHarness) -> None:
    """An unknown (session, pid) pair is a 404 — and the log_path is
    never client-controlled (no traversal possible: there is no path
    param at all)."""
    session_id = "sess_bg_api_log_404_001"
    _create_session(harness, session_id)

    body = _get_log(harness, session_id, 123456789, expect=404)
    assert "error" in body, f"expected an error envelope: {body!r}"
