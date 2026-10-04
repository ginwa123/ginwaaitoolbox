"""Functional e2e for background-command completion (Tasks 1-3).

Exercises the cron `cleanup_stale_background_process`
(src/schedulers/cleanup_stale_background_process.zig — commits 7e39524c,
30ab8253) against a REAL pabrik binary + REAL SQLite:

  * A `session_background_process` row whose PID is dead gets notified
    into `session_queue_messages` with the JSON envelope from
    `background_process.buildCompletionMessage`:
      {pid,command,stdout,truncated,...}
    (role stays `user` — the frontend renders `<background_command>`
    rows with the shell tool card) and the row is DELETEd
    (notify-then-delete).
  * The cron fires every minute on the minute (main.zig:620-623), so the
    core test POLLs GET /api/llm/session/:id/queue_messages for up to ~90s.

Setup pattern (replay-frontend-wire-payload rule): sessions are created
via PUT /api/llm/session/:id {"name": ...} (session_update.zig
auto-creates via ensureSessionExists — same helper as
session_human_touched_at_test.py::_create_session_via_update, no LLM
profile needed). The bg row is inserted via direct sqlite3 into the
isolated HOME's agent.db
(Path(harness.temp_dir)/.config/pabrik/agent.db — WAL mode makes the
concurrent open safe; same precedent as session_human_touched_at_test.py).
The dead PID (999999999) can never be alive: it exceeds Linux's max PID
so kill(pid, 0) returns ESRCH -> isProcessRunning == false.

Covers:
  * EMPTY-QUEUE — fresh session returns {messages: [], count: 0}.
  * COMPLETION — dead-PID row -> envelope in queue_messages (poll) +
    row deleted from session_background_process.

Plan: background-command-completion, Task 4.
"""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path
from typing import Any

from harness import FunctionalHarness

# A PID that can never be alive on Linux (max pid is 4194304 by
# default; kill(999999999, 0) -> ESRCH). Fits in i32 so the cron's
# parseInt(i32) accepts the row instead of skipping it as corrupt.
DEAD_PID = 999999999

# Poll cadence for the cron tick (fires every minute on the minute,
# so worst-case wait is ~60s + processing). 5s interval x 18 polls =
# 90s budget keeps the suite under ~2min even on a slow CI runner.
POLL_INTERVAL_S = 5.0
POLL_ATTEMPTS = 18


# ─── Helpers ───────────────────────────────────────────────────────────────


def _db_path(harness: FunctionalHarness) -> Path:
    """Agent DB inside the isolated tmpdir HOME (Linux layout)."""
    return Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"


def _create_session(harness: FunctionalHarness, session_id: str) -> dict[str, Any]:
    """PUT auto-creates the sessions row (ensureSessionExists); no LLM needed."""
    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": f"bg-completion-{session_id}"},
        expect=200,
    )
    return r.json()


def _get_queue(harness: FunctionalHarness, session_id: str) -> dict[str, Any]:
    r = harness.http(
        "GET",
        f"/api/llm/session/{session_id}/queue_messages",
        expect=200,
    )
    return r.json()


def _insert_bg_row(
    harness: FunctionalHarness,
    session_id: str,
    pid: int,
    command: str,
    log_path: str,
) -> None:
    """Insert a session_background_process row while the binary runs.

    Short-lived connection + commit + close (WAL-safe; same precedent
    as session_human_touched_at_test.py's direct sessions INSERT).
    Schema mirrors migration 014: (session_id, pid, command, log_path,
    started_at, status) with composite PK (session_id, pid).
    """
    conn = sqlite3.connect(f"file:{_db_path(harness)}?mode=rw", uri=True)
    try:
        conn.execute(
            "INSERT INTO session_background_process"
            " (session_id, pid, command, log_path, started_at, status)"
            " VALUES (?, ?, ?, ?, ?, 'running')",
            (session_id, pid, command, log_path, int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()


def _count_bg_rows(harness: FunctionalHarness, session_id: str) -> int:
    conn = sqlite3.connect(f"file:{_db_path(harness)}?mode=ro", uri=True)
    try:
        cur = conn.execute(
            "SELECT COUNT(*) FROM session_background_process WHERE session_id = ?",
            (session_id,),
        )
        row = cur.fetchone()
        return int(row[0]) if row else 0
    finally:
        conn.close()


# ─── Test 1 (fast): empty queue for a fresh session ─────────────────────────


def test_queue_messages_empty_for_fresh_bg_session(
    harness: FunctionalHarness,
) -> None:
    """GET .../queue_messages on a session with no queued rows returns
    {messages: [], count: 0} — the baseline the polling test asserts
    against before the cron tick fires."""
    session_id = "sess_bg_completion_empty_001"
    _create_session(harness, session_id)

    body = _get_queue(harness, session_id)
    assert body.get("messages") == [], (
        f"fresh session should have no queue messages, got {body.get('messages')!r}"
    )
    assert body.get("count") == 0, (
        f"fresh session should have count=0, got {body.get('count')!r}"
    )


# ─── Test 2 (core): dead PID -> completion envelope + row deleted ──────────


def test_dead_background_process_notifies_completion_queue(
    harness: FunctionalHarness,
) -> None:
    """A bg row with a dead PID is picked up by the per-minute cron:
    the Task 1 envelope lands in queue_messages and the row is deleted.

    Polls (cron ticks on the minute; worst case ~60s wait). Fails after
    ~90s with the row count attached for triage.
    """
    session_id = "sess_bg_completion_core_001"
    _create_session(harness, session_id)
    assert _get_queue(harness, session_id).get("count") == 0

    # Log file lives inside the isolated tmpdir so the binary (same
    # host, same fs) can read it; content is a unique marker the
    # envelope must contain verbatim.
    marker = "bg-completion-marker-7f3a9c"
    log_path = str(Path(harness.temp_dir) / "bg-completion-test.log")
    Path(log_path).write_text(f"line one\n{marker}\nline three\n", encoding="utf-8")
    command = "sleep 10"

    _insert_bg_row(harness, session_id, DEAD_PID, command, log_path)
    assert _count_bg_rows(harness, session_id) == 1

    envelope: str | None = None
    for _ in range(POLL_ATTEMPTS):
        time.sleep(POLL_INTERVAL_S)
        body = _get_queue(harness, session_id)
        for entry in body.get("messages", []):
            msg = entry.get("message", "")
            if marker in msg:
                envelope = msg
                break
        if envelope is not None:
            break

    assert envelope is not None, (
        f"cron did not notify completion within ~{int(POLL_INTERVAL_S * POLL_ATTEMPTS)}s; "
        f"bg rows left: {_count_bg_rows(harness, session_id)}"
    )

    # JSON envelope shape (background_process.zig: buildCompletionMessage):
    # {pid,command,stdout,truncated,...} object. Role stays user — no tool_call_id, no prose header, no quote fence.
    assert '"pid":' in envelope, f"envelope missing pid key: {envelope!r}"
    assert f'"pid":{DEAD_PID}' in envelope, f"envelope pid mismatch: {envelope!r}"
    assert f'"command":"{command}"' in envelope, (
        f"envelope command mismatch: {envelope!r}"
    )
    assert marker in envelope, f"envelope missing log content: {envelope!r}"
    assert '"truncated":false' in envelope, (
        f"envelope truncated flag mismatch: {envelope!r}"
    )
    assert '"""""' not in envelope, f"envelope still uses quote fence: {envelope!r}"

    # Notify-then-delete: the row must be gone once notified (allow one
    # extra poll for the DELETE to land if the test raced the tick
    # between the queue INSERT and the batch DELETE).
    for _ in range(3):
        if _count_bg_rows(harness, session_id) == 0:
            break
        time.sleep(2.0)
    assert _count_bg_rows(harness, session_id) == 0, (
        "notified bg row should be deleted from session_background_process"
    )
