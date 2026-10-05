"""Functional test: a competed-for SQLite write must survive the wait.

THE BUG
-------
Production log, from `pabrik --port 8081`:

    warning: sqlite3 step failed: database is locked (sql: UPDATE sessions
      SET last_human_touched_at_nano = ? WHERE id = ?)
    warning: sqlite3 step failed: database is locked (sql: INSERT INTO logs (...))
    warning: frontend_log_post: Failed to persist log

WAL mode has exactly ONE writer slot per database file. A write that
cannot take it blocks for `busy_timeout` and then FAILS — the write is
lost, not delayed. The vendored `databases` package sets
`busy_timeout=5000` in `SqliteBackend.init` and nothing else, so the app
inherited a 5-second ceiling and no `synchronous` / `journal_size_limit`
policy.

WHAT THIS TEST DOES
-------------------
It reproduces the contention end-to-end, over the wire, against a REAL
pabrik binary on an ISOLATED database: a second connection takes the
writer slot and holds it for longer than 5 seconds, and the test then
POSTs the exact `/api/logs` body the desktop logger sends.

The hold is deliberately ~6.5 s — past the old 5 s ceiling — because a
shorter hold passes on the unfixed binary too and would prove nothing.
With `busy_timeout=15000` (applied at boot by `sqlite_pragmas.apply`)
the POST waits and lands; on the unfixed build it returns
`500 {"error": "Failed to persist log"}` and the row never exists.

This is the SLOW test in the suite (~8 s wall clock). It is the only
place the number 5_000 vs 15_000 is observable from outside the process.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time

import pytest

from harness import FunctionalHarness, harness_path

# How long the competing writer holds the slot. Must EXCEED the old
# busy_timeout of 5000 ms by a clear margin, or this test would also pass
# against an unfixed binary.
HOLD_SECONDS = 6.5

LOG_EVENT = {
    "level": "error",
    "kind": "console_error",
    "message": "functional-sqlite-write-lock-probe",
    "stack": "at <anonymous> (probe.js:1:1)",
    "source": "http://127.0.0.1/app.js",
    "line": 1,
    "route_path": "/chats/probe",
    "session_id": "probe-session",
}


def _db_path(harness: FunctionalHarness) -> str:
    return harness_path(harness, ".config", "pabrik", "agent.db")


class _WriteLockHolder:
    """Holds WAL's single writer slot on a SEPARATE connection.

    `BEGIN IMMEDIATE` acquires the write lock immediately; the sleep
    inside the transaction is what the server's write has to out-wait.
    """

    def __init__(self, db_path: str, hold_seconds: float) -> None:
        self._db_path = db_path
        self._hold_seconds = hold_seconds
        self._locked = threading.Event()
        self._released = threading.Event()
        self.error: BaseException | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()
        if not self._locked.wait(timeout=10):
            raise AssertionError("competing writer never took the SQLite write lock")

    def wait_released(self, timeout: float = 20.0) -> None:
        if not self._released.wait(timeout=timeout):
            raise AssertionError("competing writer never released the SQLite write lock")

    def close(self) -> None:
        """Join the holder. The connection is closed ON THE WORKER THREAD —
        ``sqlite3`` forbids touching it from anywhere else."""
        self.wait_released()
        self._thread.join(timeout=10)
        assert not self._thread.is_alive(), "competing writer thread outlived the test"

    def _run(self) -> None:
        conn = sqlite3.connect(self._db_path, timeout=10, isolation_level=None)
        try:
            conn.execute("PRAGMA busy_timeout=10000;")
            # BEGIN IMMEDIATE acquires the write lock on its own — no DDL
            # needed, and nothing is written to the harness's schema.
            conn.execute("BEGIN IMMEDIATE")
            self._locked.set()
            time.sleep(self._hold_seconds)
            conn.execute("ROLLBACK")
        except BaseException as exc:  # noqa: BLE001 — surfaced in the test
            self.error = exc
            self._locked.set()
        finally:
            conn.close()
            self._released.set()


def _fetch_log(harness: FunctionalHarness, message: str) -> dict | None:
    r = harness.http("GET", "/api/logs", params={"limit": 200}, expect=200, timeout_s=20)
    rows = r.json().get("logs") or r.json().get("data") or []
    for row in rows:
        if row.get("message") == message:
            return row
    return None


def test_log_post_waits_out_a_competing_writer_instead_of_failing(harness: FunctionalHarness) -> None:
    """POST /api/logs must return 204 while another writer holds the DB.

    This is the exact failure the bug report shows: the handler used to
    answer `500 {"error": "Failed to persist log"}` and the event was
    gone.
    """
    holder = _WriteLockHolder(_db_path(harness), HOLD_SECONDS)
    holder.start()
    try:
        started = time.monotonic()
        r = harness.http(
            "POST",
            "/api/logs",
            json_body={"events": [LOG_EVENT]},
            expect=204,
            timeout_s=30,
        )
        elapsed = time.monotonic() - started
    finally:
        holder.close()

    assert holder.error is None, f"competing writer failed: {holder.error!r}"
    # The request must actually have WAITED — a 204 that returned in 0 ms
    # would mean the lock was never contended and the test is vacuous.
    assert elapsed >= 1.0, (
        f"POST /api/logs returned in {elapsed:.3f}s while the writer slot was "
        "held — the contention never happened"
    )
    assert r.status == 204

    # And the event must actually be there — a 204 from a dropped write
    # would be indistinguishable from success at the HTTP layer.
    row = _fetch_log(harness, LOG_EVENT["message"])
    assert row is not None, f"log event was not persisted: {harness.tail_log(30)}"


def test_boot_logs_the_connection_pragma_policy(harness: FunctionalHarness) -> None:
    """The live connection's settings are visible in the boot log.

    `main.zig` prints the read-back of `sqlite_pragmas.readBack` right
    after `database.open`. This is the assertion a future "database is
    locked" report can be read against, instead of guessing what the
    connection was configured with.
    """
    r = harness.http("GET", "/health", expect=200)
    assert r.json().get("status") == "ok"

    log = harness.tail_log(400)
    assert "journal_mode=wal" in log, f"no sqlite pragma line in boot log:\n{log}"
    assert "busy_timeout=15000ms" in log, f"busy_timeout not the configured value:\n{log}"